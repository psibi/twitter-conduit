{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}

module Common where

import Secret (tokens)
import Web.Twitter.Conduit

import Web.Authenticate.OAuth (OAuth(..), Credential(..))
import qualified Web.Authenticate.OAuth as OA
import qualified Network.URI as URI
import Network.HTTP.Conduit
import Data.Aeson hiding (Error)
import qualified Data.Map as M
import qualified Data.ByteString.Lazy.Char8 as LB
import qualified Data.ByteString.Char8 as B
import qualified Data.Text.Encoding as T
import qualified Data.CaseInsensitive as CI
import Data.Default
import Control.Applicative
import Control.Monad.IO.Class
import Control.Monad.Base
import Control.Monad.Trans.Resource
import System.IO
import System.FilePath
import System.Directory
import System.Environment
import Control.Monad.Logger
import Control.Lens

ensureDirectoryExist :: FilePath -> IO FilePath
ensureDirectoryExist dir = do
  createDirectoryIfMissing True dir
  return dir

confdir :: IO FilePath
confdir = fmap (</> ".twitter2notify") getHomeDirectory >>= ensureDirectoryExist

credentialFile :: IO FilePath
credentialFile = (</> "credential.json") <$> confdir

withCF :: TW (ResourceT (NoLoggingT IO)) a -> IO a
withCF = runNoLoggingT . withCF'

withCF' :: (MonadLogger m, MonadBaseControl IO m, MonadIO m) => TW (ResourceT m) a -> m a
withCF' t = liftBase credentialFile >>= \f -> withCredentialFile f t

loadCredential :: FilePath -> IO (Maybe Credential)
loadCredential file = do
  existp <- doesFileExist file
  if existp
    then do
      content <- LB.readFile file
      return $ Credential . over (mapped . both) T.encodeUtf8 <$> decode content
    else return Nothing

saveCredential :: FilePath -> Credential -> IO ()
saveCredential file cred = LB.writeFile file $ encode . over (mapped . both) T.decodeUtf8 . unCredential $ cred

withCredentialFile :: (MonadLogger m, MonadBaseControl IO m, MonadIO m) => FilePath -> TW (ResourceT m) a -> m a
withCredentialFile file task = do
  pr <- liftBase getProxyEnv
  cred <- liftBase $ maybe (authorizeAndSave pr) return =<< loadCredential file
  let env = (setCredential tokens cred def) { twProxy = pr }
  runTW env task
  where
    getPIN url = do
      putStrLn $ "browse URL: " ++ url
      putStr "> what was the PIN twitter provided you with? "
      hFlush stdout
      getLine
    authorizeAndSave pr =
      withManager $ \mgr -> do
        cred <- authorize pr tokens getPIN mgr
        liftIO $ saveCredential file cred
        return cred

getProxyEnv :: IO (Maybe Proxy)
getProxyEnv = do
  env <- M.fromList . over (mapped . _1) CI.mk <$> getEnvironment
  let u = M.lookup "https_proxy" env <|>
          M.lookup "http_proxy" env <|>
          M.lookup "proxy" env >>= URI.parseURI >>= URI.uriAuthority
  return $ Proxy <$> (B.pack . URI.uriRegName <$> u) <*> (parsePort . URI.uriPort <$> u)
  where
    parsePort :: String -> Int
    parsePort []       = 8080
    parsePort (':':xs) = read xs
    parsePort xs       = error $ "port number parse failed " ++ xs

authorize :: Maybe Proxy -> OAuth -> (String -> IO String) -> Manager -> ResourceT IO Credential
authorize pr oauth getPIN mng = do
  cred <- OA.getTemporaryCredentialProxy pr oauth mng
  let url = OA.authorizeUrl oauth cred
  pin <- liftIO $ getPIN url
  OA.getAccessTokenProxy pr oauth (OA.insert "oauth_verifier" (B.pack pin) cred) mng
