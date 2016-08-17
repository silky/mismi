{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Test.Mismi.Autoscaling.Core.Arbitrary where

import qualified Data.List.NonEmpty as N
import qualified Data.Text as T

import           Disorder.Corpus

import           Mismi.Autoscaling.Core.Data

import           P

import           Test.Mismi.EC2.Core.Arbitrary ()
import           Test.QuickCheck
import           Test.QuickCheck.Instances ()

instance Arbitrary ConfigurationName where
  arbitrary =
    ConfigurationName
      <$> genUniqueName

instance Arbitrary GroupName where
  arbitrary =
    GroupName
      <$> genUniqueName

genUniqueName :: Gen Text
genUniqueName = do
  m <- elements muppets
  c <- elements cooking
  n <- choose (9999, 99999 :: Int)
  pure $ T.intercalate "." [
      c
    , T.pack $ show n
    , m
    ]

instance Arbitrary Propagate where
  arbitrary =
    arbitraryBoundedEnum

instance Arbitrary DesiredInstances where
  arbitrary =
    DesiredInstances <$> choose (0, 10)

instance Arbitrary GroupTag where
  arbitrary =
    GroupTag
      <$> arbitrary
      <*> arbitrary

instance Arbitrary Group where
  arbitrary =
    Group
      <$> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> (N.fromList <$> listOf1 arbitrary)
      <*> arbitrary

instance Arbitrary GroupResult where
  arbitrary =
    GroupResult
      <$> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> (N.fromList <$> listOf1 arbitrary)
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary