import           Control.Monad (unless)

import           System.Exit (exitFailure)
import           System.IO (BufferMode(..), hSetBuffering, stdout, stderr)

import qualified Test.Mismi.Control
import qualified Test.Mismi.Data

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering

  results <- sequence [
      Test.Mismi.Control.tests
    , Test.Mismi.Data.tests
    ]

  unless (and results) exitFailure
