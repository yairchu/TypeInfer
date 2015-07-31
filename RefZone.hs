{-# LANGUAGE RankNTypes, NoImplicitPrelude #-}
module RefZone
    ( Zone, new, freeze, clone
    , Ref, newRef, readRef, writeRef, modifyRef
    ) where

import           Control.Lens.Operators
import           Control.Monad.ST (ST, runST)
import           Data.STRef
import qualified Data.Vector as V
import qualified Data.Vector.Mutable as MV
import           Unsafe.Coerce

import           Prelude.Compat

data Box

unsafeFromBox :: Box -> a
unsafeFromBox = unsafeCoerce

toBox :: a -> Box
toBox = unsafeCoerce

data Zone s = Zone
    { _zoneSizeRef :: !(STRef s Int) -- vector grows beyond this
    , zoneVectorRef :: !(STRef s (MV.STVector s Box))
    }

newtype Frozen = Frozen (V.Vector Box)

newtype Ref a = Ref Int
    deriving (Eq)

new :: ST s (Zone s)
new = Zone <$> newSTRef 0 <*> (MV.new 1 >>= newSTRef)

freeze :: (forall s. ST s (Zone s, a)) -> (Frozen, a)
freeze action =
    runST $ do
        (Zone sizeRef mvectorRef, res) <- action
        size <- readSTRef sizeRef
        vector <- readSTRef mvectorRef >>= V.unsafeFreeze <&> V.slice 0 size
        return (Frozen vector, res)

clone :: Frozen -> ST s (Zone s)
clone (Frozen vector) =
    Zone
    <$> newSTRef (V.length vector)
    <*> (V.thaw vector >>= newSTRef)

{-# INLINE incSize #-}
incSize :: Zone s -> ST s (MV.STVector s Box, Int)
incSize (Zone sizeRef mvectorRef) =
    do
        size <- readSTRef sizeRef
        mvector <- readSTRef mvectorRef
        let len = MV.length mvector
        incSizeH size =<<
            if size == len
            then
            do
                doubleMvector <- MV.new (2 * len)
                MV.copy (MV.slice 0 len doubleMvector) mvector
                writeSTRef mvectorRef doubleMvector
                return doubleMvector
            else
                return mvector
    where
        -- This is separated to avoid shadowing and/or having a stale mvector in scope
        incSizeH size mvector =
            do
                writeSTRef sizeRef (size + 1)
                return (mvector, size)

{-# INLINE newRef #-}
newRef :: Zone s -> a -> ST s (Ref a)
newRef zone val =
    do
        (mvector, size) <- incSize zone
        val & toBox & MV.write mvector size
        Ref size & return

{-# INLINE readRef #-}
readRef :: Zone s -> Ref a -> ST s a
readRef zone (Ref i) =
    readSTRef (zoneVectorRef zone) >>= (MV.read ?? i) <&> unsafeFromBox

{-# INLINE writeRef #-}
writeRef :: Zone s -> Ref a -> a -> ST s ()
writeRef zone (Ref i) val =
    do
        mvector <- readSTRef (zoneVectorRef zone)
        toBox val & MV.write mvector i

{-# INLINE modifyRef #-}
modifyRef :: Zone s -> Ref a -> (a -> a) -> ST s ()
modifyRef zone (Ref i) f =
    do
        mvector <- readSTRef (zoneVectorRef zone)
        MV.read mvector i
            <&> unsafeFromBox
            <&> f
            <&> toBox
            >>= MV.write mvector i