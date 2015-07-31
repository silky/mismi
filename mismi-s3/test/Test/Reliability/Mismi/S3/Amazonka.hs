{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
module Test.Reliability.Mismi.S3.Amazonka where

import           Control.Monad.Catch

import           Data.Text (Text)
import qualified Data.Text as T

import           Disorder.Corpus

import           Mismi.S3.Data
import qualified Mismi.S3.Default as S3
import           Mismi.S3.DefaultK

import           P

import           System.IO
import           System.IO.Error

import           Test.Mismi.Amazonka (liftS3)
import           Test.Reliability.Reliability
import           Test.QuickCheck
import           Test.QuickCheck.Instances ()

prop_sync = forAll (elements muppets) $ \m -> testAWS' $ \a b i -> do
  createFiles a m i
  syncWithMode OverwriteSync a b 10
  mapM_ (\e -> exists e >>= \e' -> when (e' == False) (throwM $ userError "Output files do not exist")) (files a m i)
  pure $ True === True

createFiles :: Address -> Text -> Int -> AWS ()
createFiles prefix name n = do
  mapM_ (liftS3 . flip S3.write "data") $ files prefix name n

files :: Address -> Text -> Int -> [Address]
files prefix name n =
  fmap (\i -> withKey (</> Key (name <> "-" <> (T.pack $ show i))) prefix) [1..n]

return []
tests :: IO Bool
tests =
  getMaxSuccess >>= testsN

testsN :: Int -> IO Bool
testsN n =
  $forAllProperties $ quickCheckWithResult (stdArgs { maxSuccess = n })
