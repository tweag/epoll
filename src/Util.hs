-- |
-- Module      : Util
-- Copyright   : (c) 2009 Toralf Wittner
-- License     : LGPL
-- Maintainer  : toralf.wittner@gmail.com
-- Stability   : internal
-- Portability : portable

module Util where

import Control.Concurrent (forkIO)
import Data.Word

intToNum :: (Integral a, Num b) => a -> b
intToNum = fromIntegral . toInteger

toWord32 :: Int -> Maybe Word32
toWord32 i | i < 0     = Nothing
           | otherwise = Just (fromIntegral i)

forkIO_ :: IO () -> IO ()
forkIO_ act = forkIO act >> return ()

