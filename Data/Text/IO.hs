{-# LANGUAGE BangPatterns, CPP, RecordWildCards #-}
-- |
-- Module      : Data.Text.IO
-- Copyright   : (c) Bryan O'Sullivan 2009,
--               (c) Simon Marlow 2009
-- License     : BSD-style
-- Maintainer  : bos@serpentine.com
-- Stability   : experimental
-- Portability : GHC
--
-- Efficient locale-sensitive support for text I\/O.

module Data.Text.IO
    (
    -- * Locale support
    -- $locale
    -- * File-at-a-time operations
      readFile
    , writeFile
    , appendFile
    -- * Operations on handles
    , hGetContents
    , hGetLine
    , hPutStr
    , hPutStrLn
    -- * Special cases for standard input and output
    , interact
    , getContents
    , getLine
    , putStr
    , putStrLn
    ) where

import Data.Text (Text)
import Prelude hiding (appendFile, getContents, getLine, interact, putStr,
                       putStrLn, readFile, writeFile)
import System.IO (Handle, IOMode(..), hPutChar, openFile, stdin, stdout,
                  withFile)
#if __GLASGOW_HASKELL__ <= 610
import qualified Data.ByteString.Char8 as B
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
#else
import Control.Exception (throw)
import Data.IORef (readIORef, writeIORef)
import qualified Data.Text as T
import Data.Text.Fusion (stream, unstream)
import Data.Text.Fusion.Internal (Step(..), Stream(..))
import Data.Text.Fusion.Size (exactSize, maxSize)
import Data.Text.Unsafe (inlinePerformIO)
import Foreign.Storable (peekElemOff)
import GHC.IO.Buffer (Buffer(..), BufferState(..), CharBufElem, CharBuffer,
                      RawCharBuffer, bufferAdjustL, bufferElems, charSize,
                      emptyBuffer, isEmptyBuffer, newCharBuffer, readCharBuf,
                      withRawBuffer, writeCharBuf)
import GHC.IO.Handle.Internals (augmentIOError, ioe_EOF, readTextDevice,
                                wantReadableHandle_, hClose_help,
                                wantReadableHandle, wantWritableHandle)
import GHC.IO.Handle.Text (commitBuffer')
import GHC.IO.Handle.Types (BufferList(..), BufferMode(..), Handle__(..),
                            Newline(..))
import System.IO.Error (isEOFError)
#endif

-- | The 'readFile' function reads a file and returns the contents of
-- the file as a string.  The entire file is read strictly, as with
-- 'getContents'.
readFile :: FilePath -> IO Text
readFile name = openFile name ReadMode >>= hGetContents

-- | Write a string to a file.  The file is truncated to zero length
-- before writing begins.
writeFile :: FilePath -> Text -> IO ()
writeFile p = withFile p WriteMode . flip hPutStr

-- | Write a string the end of a file.
appendFile :: FilePath -> Text -> IO ()
appendFile p = withFile p AppendMode . flip hPutStr

-- | Read the remaining contents of a 'Handle' as a string.  The
-- 'Handle' is closed once the contents have been read, or if an
-- exception is thrown.
--
-- Internally, this function reads a chunk at a time from the
-- lower-level buffering abstraction, and concatenates the chunks into
-- a single string once the entire file has been read.
--
-- As a result, it requires approximately twice as much memory as its
-- result to construct its result.  For files more than a half of
-- available RAM in size, this may result in memory exhaustion.
hGetContents :: Handle -> IO Text
#if __GLASGOW_HASKELL__ <= 610
hGetContents = fmap decodeUtf8 . B.hGetContents
#else
hGetContents h = wantReadableHandle "hGetContents" h $ \hh -> do
                   (hh',ts) <- readAll hh
                   return (hh',T.concat ts)
 where
  readAll hh@Handle__{..} = do
    buf <- readIORef haCharBuffer
    let readChunks = do
          buf'@Buffer{..} <- getSomeCharacters hh buf
          (t,r) <- if haInputNL == CRLF
                   then unpack_nl bufRaw bufL bufR
                   else do t <- unpack bufRaw bufL bufR
                           return (t,bufR)
          writeIORef haCharBuffer (bufferAdjustL r buf')
          (hh',ts) <- readAll hh
          return (hh', t:ts)
    readChunks `catch` \e -> do
      (hh', _) <- hClose_help hh
      if isEOFError e
        then return $ if isEmptyBuffer buf
                      then (hh', [])
                      else (hh', [T.singleton '\r'])
        else throw (augmentIOError e "hGetContents" h)
#endif

-- | Read a single line from a handle.
hGetLine :: Handle -> IO Text
#if __GLASGOW_HASKELL__ <= 610
hGetLine = fmap decodeUtf8 . B.hGetLine
#else
hGetLine h = wantReadableHandle_ "hGetLine" h go
  where go hh@Handle__{..} = readIORef haCharBuffer >>= hGetLineLoop hh []

hGetLineLoop :: Handle__ -> [Text] -> CharBuffer -> IO Text
hGetLineLoop hh@Handle__{..} ts buf@Buffer{ bufL=r0, bufR=w, bufRaw=raw0 } = do
  let findEOL raw r
          | r == w    = return (False, w)
          | otherwise = do
        (c,r') <- readCharBuf raw r
        if c == '\n'
          then return (True, r)
          else findEOL raw r'
  (eol, off) <- findEOL raw0 r0
  (t,r') <- if haInputNL == CRLF
            then unpack_nl raw0 r0 off
            else do t <- unpack raw0 r0 off
                    return (t,off)
  if eol
    then do writeIORef haCharBuffer (bufferAdjustL (off+1) buf)
            return $! T.concat (reverse (t:ts))
    else do
      let buf1 = bufferAdjustL r' buf
      maybe_buf <- maybeFillReadBuffer hh buf1
      case maybe_buf of
         -- Nothing indicates we caught an EOF, and we may have a
         -- partial line to return.
         Nothing -> do
              -- we reached EOF.  There might be a lone \r left
              -- in the buffer, so check for that and
              -- append it to the line if necessary.
              let pre | isEmptyBuffer buf1 = T.empty
                      | otherwise          = T.singleton '\r'
              writeIORef haCharBuffer buf1{ bufL=0, bufR=0 }
              let str = T.concat . reverse $ pre:t:ts
              if T.null str
                then ioe_EOF
                else return str
         Just new_buf -> hGetLineLoop hh (t:ts) new_buf

-- This function is lifted almost verbatim from GHC.IO.Handle.Text.
maybeFillReadBuffer :: Handle__ -> CharBuffer -> IO (Maybe CharBuffer)
maybeFillReadBuffer handle_ buf
  = catch (Just `fmap` getSomeCharacters handle_ buf) $ \e ->
      if isEOFError e 
      then return Nothing 
      else ioError e

unpack :: RawCharBuffer -> Int -> Int -> IO Text
unpack !buf !r !w
 | charSize /= 4 = sizeError "unpack"
 | r >= w        = return T.empty
 | otherwise     = withRawBuffer buf go
 where
  go pbuf = return $! unstream (Stream next r (exactSize (w-r)))
   where
    next !i | i >= w    = Done
            | otherwise = Yield (ix i) (i+1)
    ix i = inlinePerformIO $ peekElemOff pbuf i

unpack_nl :: RawCharBuffer -> Int -> Int -> IO (Text, Int)
unpack_nl !buf !r !w
 | charSize /= 4 = sizeError "unpack_nl"
 | r >= w        = return (T.empty, 0)
 | otherwise     = withRawBuffer buf $ go
 where
  go pbuf = do
    let t = unstream (Stream next r (maxSize (w-r)))
        w' = w - 1
    return $ if ix w' == '\r'
             then (t,w')
             else (t,w)
   where
    next !i | i >= w = Done
            | c == '\r' = let i' = i + 1
                          in if i' < w
                             then if ix i' == '\n'
                                  then Yield '\n' (i+2)
                                  else Yield '\n' i'
                             else Done
            | otherwise = Yield c (i+1)
            where c = ix i
    ix i = inlinePerformIO $ peekElemOff pbuf i

sizeError :: String -> a
sizeError loc = error $ "Data.Text.IO." ++ loc ++ ": bad internal buffer size"

-- This function is completely lifted from GHC.IO.Handle.Text.
getSomeCharacters :: Handle__ -> CharBuffer -> IO CharBuffer
getSomeCharacters handle_@Handle__{..} buf@Buffer{..} =
  case bufferElems buf of
    -- buffer empty: read some more
    0 -> readTextDevice handle_ buf

    -- if the buffer has a single '\r' in it and we're doing newline
    -- translation: read some more
    1 | haInputNL == CRLF -> do
      (c,_) <- readCharBuf bufRaw bufL
      if c == '\r'
         then do -- shuffle the '\r' to the beginning.  This is only safe
                 -- if we're about to call readTextDevice, otherwise it
                 -- would mess up flushCharBuffer.
                 -- See [note Buffer Flushing], GHC.IO.Handle.Types
                 _ <- writeCharBuf bufRaw 0 '\r'
                 let buf' = buf{ bufL=0, bufR=1 }
                 readTextDevice handle_ buf'
         else do
                 return buf

    -- buffer has some chars in it already: just return it
    _otherwise -> return buf
#endif

-- | Write a string to a handle.
hPutStr :: Handle -> Text -> IO ()
#if __GLASGOW_HASKELL__ <= 610
hPutStr h = B.hPutStr h . encodeUtf8
#else
-- This function is lifted almost verbatim from GHC.IO.Handle.Text.
hPutStr h t = do
  (buffer_mode, nl) <- 
       wantWritableHandle "hPutStr" h $ \h_ -> do
                     bmode <- getSpareBuffer h_
                     return (bmode, haOutputNL h_)
  let str = stream t
  case buffer_mode of
     (NoBuffering, _)        -> hPutChars h str
     (LineBuffering, buf)    -> writeBlocks h True  nl buf str
     (BlockBuffering _, buf) -> writeBlocks h False nl buf str

hPutChars :: Handle -> Stream Char -> IO ()
hPutChars h (Stream next0 s0 _len) = loop s0
  where
    loop !s = case next0 s of
                Done       -> return ()
                Skip s'    -> loop s'
                Yield x s' -> hPutChar h x >> loop s'

-- This function is largely lifted from GHC.IO.Handle.Text, but
-- adapted to a coinductive stream of data instead of an inductive
-- list.
writeBlocks :: Handle -> Bool -> Newline -> Buffer CharBufElem -> Stream Char
            -> IO ()
writeBlocks h lineBuffered nl buf0 (Stream next0 s0 _len) = outer s0 buf0
 where
  outer s1 Buffer{bufRaw=raw, bufSize=len} = inner s1 (0::Int)
   where
    inner !s !n =
      case next0 s of
        Done -> commit n False{-no flush-} True{-release-} >> return ()
        Skip s' -> inner s' n
        Yield x s'
          | n + 1 >= len -> commit n True{-needs flush-} False >>= outer s
          | x == '\n'    -> do
                   n' <- if nl == CRLF
                         then do n1 <- writeCharBuf raw n '\r'
                                 writeCharBuf raw n1 '\n'
                         else writeCharBuf raw n x
                   if lineBuffered
                     then commit n' True{-needs flush-} False >>= outer s'
                     else inner s' n'
          | otherwise    -> writeCharBuf raw n x >>= inner s'
    commit = commitBuffer h raw len

-- This function is completely lifted from GHC.IO.Handle.Text.
getSpareBuffer :: Handle__ -> IO (BufferMode, CharBuffer)
getSpareBuffer Handle__{haCharBuffer=ref, 
                        haBuffers=spare_ref,
                        haBufferMode=mode}
 = do
   case mode of
     NoBuffering -> return (mode, error "no buffer!")
     _ -> do
          bufs <- readIORef spare_ref
          buf  <- readIORef ref
          case bufs of
            BufferListCons b rest -> do
                writeIORef spare_ref rest
                return ( mode, emptyBuffer b (bufSize buf) WriteBuffer)
            BufferListNil -> do
                new_buf <- newCharBuffer (bufSize buf) WriteBuffer
                return (mode, new_buf)


-- This function is completely lifted from GHC.IO.Handle.Text.
commitBuffer :: Handle -> RawCharBuffer -> Int -> Int -> Bool -> Bool
             -> IO CharBuffer
commitBuffer hdl !raw !sz !count flush release = 
  wantWritableHandle "commitAndReleaseBuffer" hdl $
     commitBuffer' raw sz count flush release
{-# NOINLINE commitBuffer #-}
#endif

-- | Write a string to a handle, followed by a newline.
hPutStrLn :: Handle -> Text -> IO ()
hPutStrLn h t = hPutStr h t >> hPutChar h '\n'

-- | The 'interact' function takes a function of type @Text -> Text@
-- as its argument. The entire input from the standard input device is
-- passed to this function as its argument, and the resulting string
-- is output on the standard output device.
interact :: (Text -> Text) -> IO ()
interact f = putStr . f =<< getContents

-- | Read all user input on 'stdin' as a single string.
getContents :: IO Text
getContents = hGetContents stdin

-- | Read a single line of user input from 'stdin'.
getLine :: IO Text
getLine = hGetLine stdin

-- | Write a string to 'stdout'.
putStr :: Text -> IO ()
putStr = hPutStr stdout

-- | Write a string to 'stdout', followed by a newline.
putStrLn :: Text -> IO ()
putStrLn = hPutStrLn stdout

-- $locale
--
-- /Note/: The behaviour of functions in this module depends on the
-- version of GHC you are using.
--
-- Beginning with GHC 6.12, text I\/O is performed using the system or
-- handle's current locale and line ending conventions.
--
-- Under GHC 6.10 and earlier, the system I\/O libraries /do not
-- support/ locale-sensitive I\/O or line ending conversion.  On these
-- versions of GHC, functions in this library all use UTF-8.  What
-- does this mean in practice?
--
-- * All data that is read will be decoded as UTF-8.
--
-- * Before data is written, it is first encoded as UTF-8.
--
-- * On both reading and writing, the platform's native newline
--   conversion is performed.
--
-- If you must use a non-UTF-8 locale on an older version of GHC, you
-- will have to perform the transcoding yourself, e.g. as follows:
--
-- > import qualified Data.ByteString as B
-- > import Data.Text (Text)
-- > import Data.Text.Encoding (encodeUtf16)
-- >
-- > putStr_Utf16LE :: Text -> IO ()
-- > putStr_Utf16LE t = B.putStr (encodeUtf16LE t)