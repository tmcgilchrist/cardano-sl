{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving #-}
module Test.Pos.Binary.Class.CoreSpec
    ( spec
    ) where

import           Data.Bits (unsafeShiftR)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BS.Lazy
import           Data.Char (GeneralCategory(Surrogate), generalCategory)
import           Data.Fixed (Fixed (..), Nano)
import           Data.Hashable (Hashable)
import qualified Data.HashMap.Strict as HM
import qualified Data.HashSet as HS
import qualified Data.Map as M
import           Data.Tagged (Tagged (..))
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V
import           Test.Hspec (Spec, describe, it)
import           Test.QuickCheck (Arbitrary (..), Gen, Property, arbitrary, choose, listOf, forAll, oneof, resize, sized, suchThat, (===))
import           Universum

import           Pos.Binary.Class (Bi (..), serialize)


encodedSizeProp :: forall a. (Bi a, Show a) => Gen a -> Property
encodedSizeProp gen = forAll gen encodedSizeProp'

encodedSizeProp' :: forall a. (Bi a, Show a) => a -> Property
encodedSizeProp' a =
    encodedSize a === fromIntegral (length $ serialize a)

encodedListSizeProp :: forall a. (Bi a, Show a) => Gen a -> Property
encodedListSizeProp gen = forAll (listOf gen) $ \as ->
    encodedListSize as === fromIntegral (length $ serialize as)

charGen :: Gen Char
charGen = oneof
    [ choose (chr 0, chr 0x7f)
    , choose (chr 0x80, chr 0x7ff)
    , choose (chr 0x800, chr 0xffff)
    , choose (chr 0x1000, chr 0x10ffff)
    ]
    `suchThat` (not . isSurrogate)
    where
    isSurrogate c = generalCategory c == Surrogate

word16Gen :: Gen Word16
word16Gen = oneof
    [ choose (0, 0x17)
    , choose (0x18, 0xff)
    , choose (0x100, 0xffff)
    ]

word32Gen :: Gen Word32
word32Gen = oneof
    [ choose (0, 0x17)
    , choose (0x18, 0xff)
    , choose (0x100, 0xffff)
    , choose (0x10000, 0xffffffff)
    ]

word64Gen :: Gen Word64
word64Gen = oneof
    [ choose (0, 0x17)
    , choose (0x18, 0xff)
    , choose (0x100, 0xffff)
    , choose (0x10000, 0xffffffff)
    , choose (0x100000000, 0xfffffffff)
    ]

int32Gen :: Gen Int32
int32Gen = do
    sign <- arbitrary
    -- `suchThat` is not needed, since anyway `word32` generates integers
    -- smaller than the limit.
    w <- word32Gen `suchThat` (<= unsafeShiftR (maxBound @Word32) 1)
    if sign
        then return $ fromIntegral w
        else return $ (-1) * fromIntegral w

int64Gen :: Gen Int64
int64Gen = do
    sign <- arbitrary
    -- `suchThat` is not needed, since anyway `word64` generates integers
    -- smaller than the limit.
    w <- word64Gen `suchThat` (<= unsafeShiftR (maxBound @Word64) 1)
    if sign
        then return $ fromIntegral w
        else return $ (-1) * fromIntegral w

integerGen :: Gen Integer
integerGen = oneof
    [ choose (min32, max32)
    , choose (min64, min32)
    , choose (max32, max64)
    , choose (8 * min64, min64)
    , choose (max64, 8 * max64)
    ]
    where
    min32 = fromIntegral $ minBound @Int32
    max32 = fromIntegral $ maxBound @Int32
    min64 = fromIntegral $ minBound @Int64
    max64 = fromIntegral $ maxBound @Int64

floatGen :: Gen Float
floatGen = oneof
    [ choose (-100.0, 100.0)
    , choose (-10.0**9, -10.0**8)
    , choose (10.0**8, 10.0**9)
    ]

-- | Newtype wrapper for arbitrary instance
newtype HashMapA k v = HashMapA (HM.HashMap k v)
    deriving (Show)

deriving instance (Bi k, Bi v, Hashable k, Ord k) => Bi (HashMapA k v)

instance (Arbitrary k, Arbitrary v, Hashable k, Eq k) => Arbitrary (HashMapA k v) where
    arbitrary = sized $ \size ->
        HashMapA . HM.fromList <$> replicateM size arbitrary
    shrink (HashMapA a) =
        let l = HM.toList a
        in map (HashMapA . HM.fromList) $ shrink l

newtype HashSetA k = HashSetA (HS.HashSet k)
    deriving (Show)

deriving instance (Bi k, Hashable k, Ord k) => Bi (HashSetA k)

instance (Arbitrary k, Hashable k, Eq k) => Arbitrary (HashSetA k) where
    arbitrary = sized $ \size ->
        HashSetA . HS.fromList <$> replicateM size arbitrary
    shrink (HashSetA a) =
        let l = HS.toList a
        in map (HashSetA . HS.fromList) $ shrink l

newtype MapA k v = MapA (M.Map k v)
    deriving (Show)

deriving instance (Bi k, Bi v, Ord k) => Bi (MapA k v)

instance (Arbitrary k, Arbitrary v, Hashable k, Ord k) => Arbitrary (MapA k v) where
    arbitrary = sized $ \size ->
        MapA . M.fromList <$> replicateM size arbitrary
    shrink (MapA a) =
        let l = M.toList a
        in map (MapA . M.fromList) $ shrink l

newtype VectorA k = VectorA (V.Vector k)
    deriving (Show)

deriving instance (Bi k) => Bi (VectorA k)

instance (Arbitrary k) => Arbitrary (VectorA k) where
    arbitrary = sized $ \size ->
        VectorA . V.fromList <$> replicateM size arbitrary
    shrink (VectorA a) =
        let l = V.toList a
        in map (VectorA . V.fromList) (shrink l)

spec :: Spec
spec = describe "Bi" $ do
    it "encodedSize ()" $ encodedSizeProp @() arbitrary
    it "encodedListSize ()" $ encodedListSizeProp @() arbitrary

    it "encodedSize Char" $ encodedSizeProp charGen
    it "encodedListSize Char" $ encodedListSizeProp charGen

    it "encodedSize Bool" $ encodedSizeProp @Bool arbitrary
    it "encodedListSize Bool" $ encodedListSizeProp @Bool arbitrary

    it "encodedSize Word" $ encodedSizeProp @Word (fromIntegral <$> word64Gen)
    it "encodedListSize Word" $ encodedListSizeProp @Word (fromIntegral <$> word64Gen)

    it "encodedSize Word8" $ encodedSizeProp @Word8 arbitrary
    it "encodedListSize Word8" $ encodedListSizeProp @Word8 arbitrary

    it "encodedSize Word16" $ encodedSizeProp word16Gen
    it "encodedListSize Word16" $ encodedListSizeProp word16Gen

    it "encodedSize Word32" $ encodedSizeProp word32Gen
    it "encodedListSize Word32" $ encodedListSizeProp word32Gen

    it "encodedSize Word64" $ encodedSizeProp word64Gen
    it "encodedListSize Word64" $ encodedListSizeProp word64Gen

    it "encodedSize Int" $ encodedSizeProp @Int (fromIntegral <$> int64Gen)
    it "encodedListSize Int" $ encodedListSizeProp @Int (fromIntegral <$> int64Gen)

    it "encodedSize Int32" $ encodedSizeProp int32Gen
    it "encodedListSize Int32" $ encodedListSizeProp int32Gen

    it "encodedSize Int64" $ encodedSizeProp int64Gen
    it "encodedListSize Int64" $ encodedListSizeProp int64Gen

    it "encodedSize Integer" $ encodedSizeProp integerGen
    it "encodedListSize Integer" $ encodedListSizeProp integerGen

    it "encodedSize Nano" $ encodedSizeProp @Nano (MkFixed <$> integerGen)
    it "encodedListSize Nano" $ encodedListSizeProp @Nano (fromIntegral <$> integerGen)

    it "encodedSize Float" $ encodedSizeProp floatGen
    it "encodedListSize Float" $ encodedListSizeProp floatGen

    it "encodedSize Tagged" $ encodedSizeProp @(Tagged Void Char) (Tagged <$> charGen)
    it "encodedListSize Tagged" $ encodedListSizeProp @(Tagged Void Char) (Tagged <$> charGen)

    it "encodedSize (Float, Integer)" $ encodedSizeProp $ (,) <$> floatGen <*> integerGen
    it "encodedListSize (Float, Integer)" $ encodedListSizeProp $ (,) <$> floatGen <*> integerGen

    it "encodedSize (Float, Integer, Word32)" $ encodedSizeProp $ (,,) <$> floatGen <*> integerGen <*> word32Gen
    it "encodedListSize (Float, Integer, Word32)" $ encodedListSizeProp $ (,,) <$> floatGen <*> integerGen <*> word32Gen

    it "encodedSize (Float, Integer, Word32, Char)" $ encodedSizeProp $ (,,,) <$> floatGen <*> integerGen <*> word32Gen <*> charGen
    it "encodedListSize (Float, Integer, Word32, Char)" $ encodedListSizeProp $ (,,,) <$> floatGen <*> integerGen <*> word32Gen <*> charGen

    it "encodedSize ByteString" $ encodedSizeProp (BS.pack <$> listOf arbitrary)
    it "encodedListSize ByteString" $ encodedListSizeProp (BS.pack <$> listOf arbitrary)

    it "encodedSize Lazy.ByteString" $ encodedSizeProp (BS.Lazy.pack <$> listOf arbitrary)
    it "encodedListSize Lazy.ByteString" $ encodedListSizeProp (BS.Lazy.pack <$> listOf arbitrary)

    it "encodedSize Text" $ encodedSizeProp @Text (T.pack <$> listOf charGen)
    it "encodedListSize Text" $ encodedListSizeProp @Text (T.pack <$> listOf charGen)

    -- the (Bi a => Bi [a]) instance:
    it "encodedSize [Char]" $ encodedSizeProp @[Char] (listOf charGen)
    it "encodedListSize [[Char]]" $ encodedListSizeProp @[Char] (listOf charGen)

    it "encodedSize (Either Char Integer)" $ encodedSizeProp @(Either Char Integer) arbitrary
    it "encodedListSize (Either Char Integer)" $ encodedListSizeProp @(Either Char Integer) arbitrary

    it "encodedSize (NonEmpty Integer)" $ encodedSizeProp @(NonEmpty Integer) arbitrary
    it "encodedListSize [NonEmpty Integer]" $ encodedListSizeProp @(NonEmpty Integer) arbitrary

    it "encodedSize (Maybe Word8)" $ encodedSizeProp @(Maybe Word8) arbitrary
    it "encodedListSize (Maybe Word8)" $ encodedListSizeProp @(Maybe Word8) arbitrary

    it "encodedSize (HashMap Int Char)" $ encodedSizeProp @(HashMapA Int Char) (resize 0x200 arbitrary)
    -- test one value that is greater than 0xffff
    it "encodedSize (HashMap Integer Integer) (big)" $ encodedSizeProp' @(HashMapA Integer Integer) (HashMapA $ HM.fromList $ map (\x -> (x,x)) $ take 0x11000 [1..])
    it "encodedListSize (HashMap Int Char)" $ encodedListSizeProp @(HashMapA Int Char) arbitrary

    it "encodedSize (HashSet Char)" $ encodedSizeProp @(HashSetA Char) (resize 0x200 arbitrary)
    -- test one value that is greater than 0xffff
    it "encodedSize (HashSet Integer) (big)" $ encodedSizeProp' @(HashSetA Integer) (HashSetA $ HS.fromList $ take 0x11000 [1..])
    it "encodedListSize (HashSet Char)" $ encodedListSizeProp @(HashSetA Char) arbitrary

    it "encodedSize (Map Int Char)" $ encodedSizeProp @(MapA Int Char) arbitrary
    it "encodedSize (Map Int Char) (big)" $ encodedSizeProp' @(MapA Integer Integer) (MapA $ M.fromList $ map (\x -> (x,x)) $ take 0x11000 [1..])
    it "encodedListSize (Map Int Char)" $ encodedListSizeProp @(MapA Int Char) arbitrary

    it "encodedSize (Vector Int)" $ encodedSizeProp @(VectorA Int) arbitrary
    it "encodedListSize (Vector Int)" $ encodedListSizeProp @(VectorA Int) arbitrary
