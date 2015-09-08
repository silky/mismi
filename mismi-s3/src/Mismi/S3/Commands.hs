{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PackageImports #-}
module Mismi.S3.Commands (
    module AWS
  , module A
  , headObject
  , exists
  , getSize
  , delete
  , read
  , copy
  , copyWithMode
  , move
  , upload
  , uploadWithMode
  , multipartUpload'
  , uploadSingle
  , write
  , writeWithMode
  , getObjects
  , getObjectsRecursively
  , listObjects
  , list
  , list'
  , download
  , downloadWithMode
  , downloadSingle
  , downloadWithRange
  , multipartDownload
  , listMultipartParts
  , listMultiparts
  , listOldMultiparts
  , listOldMultiparts'
  , abortMultipart
  , abortMultipart'
  , filterOld
  , filterNDays
  , listRecursively
  , listRecursively'
  , sync
  , syncWithMode
  , retryAWSAction
  , retryAWS
  , retryAWS'
  , sse
  ) where


import           Control.Arrow ((***))

import           Control.Concurrent
import           Control.Concurrent.MSem

import           Control.Concurrent.Async.Lifted

import           Control.Exception.Lens
import           Control.Lens
import           Control.Retry
import           Control.Monad.Catch
import           Control.Monad.Morph (hoist)
import           Control.Monad.Trans.Resource
import           Control.Monad.Reader (ask, local)
import           Control.Monad.IO.Class

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS

import           Data.Conduit
import qualified Data.Conduit.List as DC
import           Data.Conduit.Binary

import qualified Data.List as L
import qualified Data.List.NonEmpty as NEL
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TL
import           Data.Time.Clock

import           Mismi.Control (runAWS)
import qualified Mismi.Control as A
import           Mismi.S3.Data
import           Mismi.S3.Internal

import           Network.AWS.Error
import           Network.AWS hiding (runAWS)
import           Network.AWS.S3 hiding (headObject, Bucket, bucket, listObjects)
import qualified Network.AWS.S3 as AWS
import           Network.HTTP.Client (HttpException (..))
import           Network.HTTP.Types.Status -- (status500, status404)
import           Network.AWS.Data.Body
import           Network.AWS.Data.Text

import           P

import           System.IO
import           System.Directory
import           System.FilePath hiding ((</>))
import           System.Posix.IO
import qualified "unix-bytestring" System.Posix.IO.ByteString as UBS


headObject :: Address -> AWS (Maybe HeadObjectResponse)
headObject a =
  handle404 . send . fencode' AWS.headObject $ a

exists :: Address -> AWS Bool
exists a =
  headObject a >>= pure . maybe False (const True)

getSize :: Address -> AWS (Maybe Int)
getSize a =
  headObject a >>= pure . maybe Nothing (^. horsContentLength)

delete :: Address -> AWS ()
delete =
  void . send . fencode' deleteObject

getObject' :: Address -> AWS (Maybe GetObjectResponse)
getObject' =
  handle404 . send . fencode' getObject

read :: Address -> AWS (Maybe Text)
read a = do
  resp <- getObject' a
  let format y = T.concat . TL.toChunks . TL.decodeUtf8 $ y
  z <- liftIO . sequence $ (\r -> runResourceT (r ^. gorsBody . to bodyResponse $$+- sinkLbs)) <$> resp
  pure (format <$> z)

copy :: Address -> Address -> AWS ()
copy source dest =
  copyWithMode Fail source dest

copyWithMode :: WriteMode -> Address -> Address -> AWS ()
copyWithMode mode s d = do
  unlessM (exists s) . throwM $ SourceMissing CopyError s
  foldWriteMode  (whenM (exists d) . throwM . DestinationAlreadyExists $ d) (pure ()) mode
  copy' s d

copy' :: Address -> Address -> AWS ()
copy' (Address (Bucket sb) (Key sk)) (Address (Bucket b) (Key dk)) =
  void . send $ copyObject (BucketName b) (sb <> "/" <> sk) (ObjectKey dk)
     & coServerSideEncryption .~ Just sse & coMetadataDirective .~ Just Copy

move :: Address -> Address -> AWS ()
move source destination' =
  copy source destination' >>
    delete source

upload :: FilePath -> Address -> AWS ()
upload =
  uploadWithMode Fail

uploadWithMode :: WriteMode -> FilePath -> Address -> AWS ()
uploadWithMode m f a = do
  when (m == Fail) . whenM (exists a) . throwM . DestinationAlreadyExists $ a
  unlessM (liftIO $ doesFileExist f) . throwM . SourceFileMissing $ f
  s <- liftIO $ withFile f ReadMode $ \h ->
    hFileSize h
  let chunk = 100 * 1024 * 1024
  if s < chunk
    then do
      uploadSingle f a
    else do
      if (s > 1024 * 1024 * 1024)
         then multipartUpload' f a s (10 * chunk)
         else multipartUpload' f a s chunk

uploadSingle :: FilePath -> Address -> AWS ()
uploadSingle file a = do
  x <- liftIO $ LBS.readFile file
  void . send $ fencode' putObject a (toBody x) & poServerSideEncryption .~ pure sse

multipartUpload' :: FilePath -> Address -> Integer -> Integer -> AWS ()
multipartUpload' file a fileSize chunk = do
  e <- ask
  mpu' <- send $ fencode' createMultipartUpload a & cmuServerSideEncryption .~ pure sse
  mpu <- maybe (throwM . Invariant $ "MultipartUpload: missing 'UploadId'") pure (mpu' ^. cmursUploadId)

  let chunks = calculateChunks (fromInteger fileSize) (fromInteger chunk)
  let uploader :: (Int, Int, Int) -> IO UploadPartResponse
      uploader (o, c, i) = withFile file ReadMode $ \h -> do
         req' <- liftIO $ do
           hSeek h AbsoluteSeek (toInteger o)
           cont <- LBS.hGetContents h
           let bod = toBody (LBS.take (fromIntegral c) cont)
           return $ fencode' uploadPart a i mpu bod
         runAWS e $ send req'

  handle' mpu $ do
    prts <- liftIO $ mapConcurrently uploader chunks
    ets <- mapM (\p -> maybe (throwM . Invariant $ "uprsETag") return (p ^. uprsETag)) prts
    let cps = L.zipWith (\(_, _, i) et -> completedPart i et) chunks ets
    ncps <- if cps == [] then throwM . Invariant $ "completedPart" else return . NEL.nonEmpty $ cps
    void . send $ fencode' completeMultipartUpload a mpu &
      cMultipartUpload .~ (pure $ completedMultipartUpload & cmuParts .~ ncps)
  where
    handle' mpu = flip catchAll $ const . void . send . fencode' abortMultipartUpload a $ mpu

write :: Address -> Text -> AWS ()
write =
  writeWithMode Fail

writeWithMode :: WriteMode -> Address -> Text -> AWS ()
writeWithMode w a t = do
  case w of
    Fail -> whenM (exists a) . throwM . DestinationAlreadyExists $ a
    Overwrite -> return ()
  void . send $ fencode' putObject a (toBody . T.encodeUtf8 $ t) & poServerSideEncryption .~ Just sse

-- pair of prefixs and keys
getObjects :: Address -> AWS ([Key], [Key])
getObjects (Address (Bucket buck) (Key ky)) =
  ((Key <$>) *** ((\(ObjectKey t) -> Key t) <$>)) <$> (ff $ (AWS.listObjects (BucketName buck) & loPrefix .~ Just (pp ky) & loDelimiter .~ Just '/' ))
  where
    pp :: Text -> Text
    pp k = if T.null k then "" else if T.isSuffixOf "/" k then k else k <> "/"
    ff :: ListObjects -> AWS ([T.Text], [ObjectKey])
    ff b = do
      r <- send b
      if r ^. lorsIsTruncated == Just True
        then
        do
          let d = (maybeToList =<< fmap (^. cpPrefix) (r ^. lorsCommonPrefixes), fmap (^. oKey) (r ^. lorsContents))
          n <- ff $ b & loMarker .~ (r ^. lorsNextMarker)
          pure $ (d <> n)
        else
        pure $ (maybeToList =<< fmap (^. cpPrefix) (r ^. lorsCommonPrefixes), fmap (^. oKey) (r ^. lorsContents))

getObjectsRecursively :: Address -> AWS [Object]
getObjectsRecursively (Address (Bucket b) (Key ky)) =
  getObjects' $ (AWS.listObjects (BucketName b)) & loPrefix .~ Just (pp ky)
  where
    pp :: Text -> Text
    pp k = if T.null k then "" else if T.isSuffixOf "/" k then k else k <> "/"
    -- Hoping this will have ok performance in cases where the results are large, it shouldnt
    -- affect correctness since we search through the list for it anyway
    go x ks = (NEL.toList ks <>) <$> getObjects' (x & loMarker .~ Just (toText $ NEL.last ks ^. oKey))
    getObjects' :: ListObjects -> AWS [Object]
    getObjects' x = do
      resp <- send x
      if resp ^. lorsIsTruncated == Just True
        then
          maybe
            (throwM . Invariant $ "Truncated response with empty contents list.")
            (go x)
            (NEL.nonEmpty $ resp ^. lorsContents)
        else
          pure $ resp ^. lorsContents

-- Pair of list of prefixes and list of keys
listObjects :: Address -> AWS ([Address], [Address])
listObjects a =
  (\(p, k) -> (Address (bucket a) <$> p, Address (bucket a) <$> k) )<$> getObjects a

list :: Address -> AWS [Address]
list a =
  list' a >>= ($$ DC.consume)

list' :: Address -> AWS (Source AWS Address)
list' a@(Address (Bucket b) (Key k)) = do
  let pp kk = if T.null kk then "" else if T.isSuffixOf "/" kk then kk else kk <> "/"
  e <- ask
  pure . hoist (retryConduit e) $ (paginate $ AWS.listObjects (BucketName b) & loPrefix .~ Just (pp k) & loDelimiter .~ Just '/') =$= liftAddressAndPrefix a

liftAddressAndPrefix :: Address -> Conduit ListObjectsResponse AWS Address
liftAddressAndPrefix a =
  DC.mapFoldable (\r ->
       fmap (\o -> let ObjectKey t = o ^. oKey in a { key = Key t })(r ^. lorsContents)
    <> join (traverse (\cp -> maybeToList .fmap (\cp' -> a { key = Key cp' }) $ cp ^. cpPrefix) (r ^. lorsCommonPrefixes))
  )


download :: Address -> FilePath -> AWS ()
download = downloadWithMode Fail

downloadWithMode :: WriteMode -> Address -> FilePath -> AWS ()
downloadWithMode mode a f = do
  when (mode == Fail) . whenM (liftIO $ doesFileExist f) . throwM $ DestinationFileExists f
  liftIO $ createDirectoryIfMissing True (dropFileName f)
  r <- getObject' a
  r' <- maybe (throwM $ SourceMissing DownloadError a) pure r
  liftIO . runResourceT . ($$+- sinkFile f) $ r' ^. gorsBody ^. to bodyResponse

downloadSingle :: Address -> FilePath -> AWS ()
downloadSingle a p = do
  r <- send $ fencode' getObject a
  liftIO . withFileSafe p $ \p' ->
    runResourceT . ($$+- sinkFile p') $ r ^. gorsBody ^. to bodyResponse


multipartDownload :: Address -> FilePath -> Int -> Integer -> Int -> AWS ()
multipartDownload source destination' size chunk' fork = do
  e <- ask

  let chunk = chunk' * 1024 * 1024
  let chunks = calculateChunks size (fromInteger chunk)

  let writer :: (Int, Int, Int) -> IO ()
      writer (o, c, _) =
        let req :: AWS ()
            req = downloadWithRange source o (o + c) destination'
        in runAWS e req

  -- create sparse file
  liftIO $ withFile destination' WriteMode $ \h ->
    hSetFileSize h (toInteger size)

  sem <- liftIO $ new fork
  void . liftIO $ (mapConcurrently (with sem . writer) chunks)

downloadWithRange :: Address -> Int -> Int -> FilePath -> AWS ()
downloadWithRange source start end dest = do
  let req = fencode' getObject source & goRange .~ (Just $ downRange start end)
  r <- send req
  let p :: AWS.GetObjectResponse = r
  let y :: RsBody = p ^. AWS.gorsBody

  fd <- liftIO $ openFd dest WriteOnly Nothing defaultFileFlags
  void . liftIO $ fdSeek fd AbsoluteSeek (fromInteger . toInteger $ start)
  liftIO $ do
    let rs :: ResumableSource (ResourceT IO) BS.ByteString = y ^. to bodyResponse
    let s = awaitForever $ \bs -> liftIO $
              UBS.fdWrite fd bs
    runResourceT $ ($$+- s) rs
  liftIO $ closeFd fd

listMultipartParts :: Address -> T.Text -> AWS [Part]
listMultipartParts a uploadId = do
  let req = fencode' AWS.listParts a uploadId
  paginate req $$ DC.foldMap (^. lprsParts)

listMultiparts :: Bucket -> AWS [MultipartUpload]
listMultiparts (Bucket bn) = do
  let req = listMultipartUploads $ BucketName bn
  paginate req $$ DC.foldMap (^. lmursUploads)

listOldMultiparts :: Bucket -> AWS [MultipartUpload]
listOldMultiparts b = do
  mus <- listMultiparts b
  now <- liftIO getCurrentTime
  pure $ filter (filterOld now) mus

listOldMultiparts' :: Bucket -> Int -> AWS [MultipartUpload]
listOldMultiparts' b i = do
  mus <- listMultiparts b
  now <- liftIO getCurrentTime
  pure $ filter (filterNDays i now) mus

filterOld :: UTCTime -> MultipartUpload -> Bool
filterOld = filterNDays 7

filterNDays :: Int -> UTCTime -> MultipartUpload -> Bool
filterNDays n now m = case m ^. muInitiated of
  Nothing -> False
  Just x -> nDaysOld n now x

nDaysOld :: Int -> UTCTime -> UTCTime -> Bool
nDaysOld n now utc = do
  let n' = fromInteger $ toInteger n
  let diff = -1 * 60 * 60 * 24 * n' :: NominalDiffTime
  let boundary = addUTCTime diff now
  boundary > utc

abortMultipart :: Bucket -> MultipartUpload -> AWS ()
abortMultipart (Bucket b) mu = do
  (ObjectKey k) <- maybe (throwM $ Invariant "Multipart key missing") pure (mu ^. muKey)
  i <- maybe (throwM $ Invariant "Multipart uploadId missing") pure (mu ^. muUploadId)
  abortMultipart' (Address (Bucket b) (Key k)) i

abortMultipart' :: Address -> T.Text -> AWS ()
abortMultipart' a i =
  void . send $ fencode' abortMultipartUpload a i

listRecursively :: Address -> AWS [Address]
listRecursively a = do
  a' <- listRecursively' a
  a' $$ DC.consume

listRecursively' :: Address -> AWS (Source (AWS) Address)
listRecursively' a@(Address (Bucket bn) (Key k)) = do
  e <- ask
  pure . hoist (retryConduit e) $ (paginate $ AWS.listObjects (BucketName bn) & loPrefix .~ Just k) =$= liftAddress a

liftAddress :: Address -> Conduit ListObjectsResponse (AWS) Address
liftAddress a =
  DC.mapFoldable (\r -> (\o -> a { key = Key $ (let ObjectKey t = o ^. oKey in t) }) <$> (r ^. lorsContents) )

retryConduit :: Env -> AWS a -> AWS a
retryConduit e action =
  local (const e) action

sync :: Address -> Address -> Int -> AWS ()
sync =
  syncWithMode FailSync

syncWithMode :: SyncMode -> Address -> Address -> Int -> AWS ()
syncWithMode mode source dest fork = do
  (c, r) <- liftIO $ (,) <$> newChan <*> newChan
  e <- ask

  -- worker
  tid <- liftIO $ forM [1..fork] (const . forkIO $ worker source dest mode e c r)

  -- sink list to channel
  l <- listRecursively' source
  i <- sinkChanWithDelay 50000 l c

  -- wait for threads and lift errors
  r' <- liftIO $ waitForNResults i r
  liftIO $ forM_ tid killThread
  forM_ r' hoistWorkerResult

hoistWorkerResult :: WorkerResult -> AWS ()
hoistWorkerResult =
  foldWR throwM (pure ())

worker :: Address -> Address -> SyncMode -> Env -> Chan Address -> Chan WorkerResult -> IO ()
worker source dest mode e c errs = forever $ do
  let invariant = pure . WorkerErr $ Invariant "removeCommonPrefix"
      keep :: Address -> Key -> IO WorkerResult
      keep a k = (keep' a k >> return WorkerOk) `catch` \er -> return (WorkerErr er)

      keep' :: Address -> Key -> IO ()
      keep' a k = do
        let out = withKey (</> k) dest
            action :: AWS ()
            action = do
              let cp = copy a out
                  ex = exists out
                  te = throwM $ Target a out
              foldSyncMode
                (ifM ex te cp)
                cp
                (ifM ex (return ()) cp)
                mode
        runAWS e action

  a <- readChan c
  wr <- maybe invariant (keep a) $ removeCommonPrefix source a
  writeChan errs wr

data WorkerResult =
    WorkerOk
  | WorkerErr S3Error

foldWR :: (S3Error -> m a) -> m a -> WorkerResult -> m a
foldWR e a = \case
  WorkerOk -> a
  WorkerErr err -> e err


retryAWSAction :: RetryPolicy -> AWS a -> AWS a
retryAWSAction rp a = do
  local (retryAWS' rp) $ a

retryAWS :: Int -> Env -> Env
retryAWS i = retryAWS' (retryWithBackoff i)

retryAWS' :: RetryPolicy -> Env -> Env
retryAWS' _ e =
  let err c v = case v of
        NoResponseDataReceived -> True
        StatusCodeException s _ _ -> s == status500
        FailedConnectionException _ _ -> True
        FailedConnectionException2 _ _ _ _ -> True
        TlsException _ -> True
        _ -> (e ^. envRetryCheck) c v
  in
  e & envRetryCheck .~ err


handle404 :: AWS a -> AWS (Maybe a)
handle404 m = fmap Just m `catch` \ (e :: Error) ->
  if e ^? httpStatus == Just status404 then return Nothing else throwM e

sse :: ServerSideEncryption
sse =
  AES256
