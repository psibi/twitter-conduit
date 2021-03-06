{-# LANGUAGE OverloadedStrings #-}
module Main where

import qualified Data.Conduit as C
import qualified Data.Conduit.List as CL
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Monoid
import Control.Applicative
import Control.Monad.IO.Class
import Web.Twitter.Conduit
import System.Environment
import Common

main :: IO ()
main = withCF $ do
  status <- T.concat . map T.pack <$> liftIO getArgs
  liftIO $ T.putStrLn $ "Post message: " <> status
  res <- statusesUpdate status []
  liftIO $ print res