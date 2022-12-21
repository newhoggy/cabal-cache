{-# LANGUAGE BlockArguments    #-}
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TypeApplications  #-}

module HaskellWorks.CabalCache.Concurrent.DownloadQueue
  ( DownloadStatus(..)
  , createDownloadQueue
  , runQueue
  ) where

import Control.Monad.Catch          (MonadMask(..))
import Control.Monad.IO.Class       (MonadIO(..))
import Data.Function                ((&))
import Data.Set                     ((\\))
import HaskellWorks.CabalCache.Show (tshow)

import qualified Control.Concurrent.STM                  as STM
import qualified Control.Monad.Catch                     as CMC
import qualified Data.Relation                           as R
import qualified Data.Set                                as S
import qualified HaskellWorks.CabalCache.Concurrent.Type as Z
import qualified HaskellWorks.CabalCache.IO.Console      as CIO
import qualified Network.AWS                             as AWS
import qualified System.IO                               as IO

data DownloadStatus = DownloadSuccess | DownloadFailure deriving (Eq, Show)

createDownloadQueue :: [(Z.ProviderId, Z.ConsumerId)] -> STM.STM Z.DownloadQueue
createDownloadQueue dependencies = do
  tDependencies <- STM.newTVar (R.fromList dependencies)
  tUploading    <- STM.newTVar S.empty
  tFailures     <- STM.newTVar S.empty
  return Z.DownloadQueue {..}

takeReady :: Z.DownloadQueue -> STM.STM (Maybe Z.PackageId)
takeReady Z.DownloadQueue {..} = do
  dependencies  <- STM.readTVar tDependencies
  uploading     <- STM.readTVar tUploading
  failures      <- STM.readTVar tFailures

  let ready = R.ran dependencies \\ R.dom dependencies \\ uploading \\ failures

  case S.lookupMin ready of
    Just packageId -> do
      STM.writeTVar tUploading (S.insert packageId uploading)
      return (Just packageId)
    Nothing -> if S.null (R.ran dependencies \\ R.dom dependencies \\ failures)
      then return Nothing
      else STM.retry

commit :: Z.DownloadQueue -> Z.PackageId -> STM.STM ()
commit Z.DownloadQueue {..} packageId = do
  dependencies  <- STM.readTVar tDependencies
  uploading     <- STM.readTVar tUploading

  STM.writeTVar tUploading    $ S.delete packageId uploading
  STM.writeTVar tDependencies $ R.withoutRan (S.singleton packageId) dependencies

failDownload :: Z.DownloadQueue -> Z.PackageId -> STM.STM ()
failDownload Z.DownloadQueue {..} packageId = do
  uploading <- STM.readTVar tUploading
  failures  <- STM.readTVar tFailures

  STM.writeTVar tUploading  $ S.delete packageId uploading
  STM.writeTVar tFailures   $ S.insert packageId failures

runQueue :: (MonadIO m, MonadMask m) => Z.DownloadQueue -> (Z.PackageId -> m DownloadStatus) -> m ()
runQueue downloadQueue f = do
  maybePackageId <- (liftIO $ STM.atomically $ takeReady downloadQueue)

  case maybePackageId of
    Just packageId -> do
      downloadStatus <- f packageId
        & do CMC.handle @_ @AWS.Error \e -> do
              liftIO $ CIO.hPutStrLn IO.stderr $ "Failed download due to exception: " <> tshow e
              pure DownloadFailure
        & do CMC.handleAll \e -> do
              liftIO $ CIO.hPutStrLn IO.stderr $ "Aborting due to unexpected exception during download: " <> tshow e
              liftIO $ STM.atomically $ failDownload downloadQueue packageId
              CMC.throwM e
      case downloadStatus of
        DownloadSuccess -> do liftIO $ STM.atomically $ commit downloadQueue packageId
        DownloadFailure -> do liftIO $ STM.atomically $ failDownload downloadQueue packageId
      runQueue downloadQueue f

    Nothing -> return ()
