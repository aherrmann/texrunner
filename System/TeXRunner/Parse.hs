{-# LANGUAGE OverloadedStrings #-}

----------------------------------------------------------------------------
-- |
-- Module      :  System.TeXRunner
-- Copyright   :  (c) 2014 Christopher Chalmers
-- License     :  BSD-style (see LICENSE)
-- Maintainer  :  c.chalmers@me.com
--
-- Functions for parsing TeX output and logs.
--
-----------------------------------------------------------------------------

module System.TeXRunner.Parse
  ( -- * Box
    Box (..)
  , parseBox
    -- * Errors
  , TeXLog (..)
  , TeXError (..)
  , someError
  , badBox
  , parseUnit
  , parseLog
  ) where

import Control.Applicative
import Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Char8            (ByteString, cons)
import Data.Maybe
import Data.Monoid

data TeXLog = TeXLog
  { thisis    :: Maybe ByteString
  , numPages  :: Maybe Int
  , texErrors :: [TeXError]
  } deriving Show

instance Monoid TeXLog where
  mempty = TeXLog Nothing Nothing []
  (TeXLog prog pages1 errors1) `mappend` (TeXLog _ pages2 errors2) =
    case (pages1,pages2) of
      (Just a,_) -> TeXLog prog (Just a) (errors1 ++ errors2)
      (_,b)      -> TeXLog prog b (errors1 ++ errors2)

logFile :: Parser TeXLog
logFile = mconcat <$> many logLine
  where
    logLine = do
      prog   <- optional $ "This is " *> restOfLine
      pages  <- optional nPages
      errors <- maybeToList <$> optional someError
      _      <- restOfLine
      return $ TeXLog prog pages errors

parseLog :: ByteString -> TeXLog
parseLog = (\(Right a) -> a) . parseOnly logFile
-- the parse should never fail (I think)


-- * Boxes

-- | Data type for holding dimensions of a hbox.
data Box n = Box
  { boxHeight :: n
  , boxDepth  :: n
  , boxWidth  :: n
  } deriving Show

int :: Parser Int
int = decimal

parseBox :: Fractional n => Parser (Box n)
parseBox = do
  A.skipWhile (/='\\') <* char '\\'
  parseSingle <|> parseBox
  where
    parseSingle = do
      _ <- "box" *> int *> "=\n\\hbox("
      h <- rational <* char '+'
      d <- rational <* ")x"
      w <- rational
      --
      return $ Box (pt2bp h) (pt2bp d) (pt2bp w)

parseUnit :: Fractional n => Parser n
parseUnit = do
  A.skipWhile (/='>') <* char '>'
  skipSpace
  fmap pt2bp rational <|> parseUnit

pt2bp :: Fractional n => n -> n
pt2bp = (/1.00374)

-- * Errors

data TeXError
  = UndefinedControlSequence ByteString
  | MissingNumber
  | Missing Char
  | IllegalUnit -- (Maybe Char) (Maybe Char)
  | PackageError String String
  | LaTeXError ByteString
  | BadBox ByteString
  | EmergencyStop
  | ParagraphEnded
  | TooMany ByteString
  | DimensionTooLarge
  | TooManyErrors
  | NumberTooBig
  | ExtraBrace
  | FatalError ByteString
  | UnknownError ByteString
  deriving (Show, Eq)

someError :: Parser TeXError
someError =  "! " *> errors
  where
    errors =  undefinedControlSequence
          <|> illegalUnit
          <|> missingNumber
          <|> missing
          <|> latexError
          <|> emergencyStop
          <|> extraBrace
          <|> paragraphEnded
          <|> numberTooBig
          <|> tooMany
          <|> dimentionTooLarge
          <|> tooManyErrors
          <|> fatalError
          <|> UnknownError <$> restOfLine

noteStar :: Parser ()
noteStar = skipSpace *> "<*>" *> skipSpace

toBeReadAgain :: Parser Char
toBeReadAgain = do
  skipSpace
  _ <- "<to be read again>"
  skipSpace
  anyChar

-- insertedText :: Parser ByteString
-- insertedText = do
--   skipSpace
--   _ <- "<inserted text>"
--   skipSpace
--   restOfLine

-- General errors

undefinedControlSequence :: Parser TeXError
undefinedControlSequence = do
  _ <- "Undefined control sequence."

  _ <- optional $ do -- for context log
    skipSpace
    _ <- "system"
    let skipLines = line <|> restOfLine *> skipLines
    skipLines

  _ <- optional noteStar
  skipSpace
  _ <- optional line
  skipSpace
  UndefinedControlSequence <$> finalControlSequence

finalControlSequence :: Parser ByteString
finalControlSequence = last <$> many1 controlSequence
  where
    controlSequence = cons '\\' <$>
      (char '\\' *> takeTill (\x -> isSpace x || x=='\\'))

illegalUnit :: Parser TeXError
illegalUnit = do
  _ <- "Illegal unit of measure (pt inserted)."
  _ <- optional toBeReadAgain
  _ <- optional toBeReadAgain

  return IllegalUnit

missingNumber :: Parser TeXError
missingNumber = do
  _ <- "Missing number, treated as zero."
  _ <- optional toBeReadAgain
  _ <- optional noteStar
  return MissingNumber

badBox :: Parser TeXError
badBox = do
  s <- choice ["Underfull", "Overfull", "Tight", "Loose"]
  _ <- " \\hbox " *> char '(' *> takeTill (==')') <* char ')'
  _ <- optional line
  return $ BadBox s

missing :: Parser TeXError
missing = do
  c <- "Missing " *> anyChar <* " inserted."
  _ <- optional line
  return $ Missing c

line :: Parser Int
line =  " detected at line " *> decimal
    <|> "l."                 *> decimal

emergencyStop :: Parser TeXError
emergencyStop = "Emergency stop."
             *> return EmergencyStop

fatalError :: Parser TeXError
fatalError = FatalError <$> (" ==> Fatal error occurred, " *> restOfLine)

-- line 8058 tex.web
extraBrace :: Parser TeXError
extraBrace = "Argument of" *> return ExtraBrace

tooMany :: Parser TeXError
tooMany = TooMany <$> ("Too Many " *> takeTill (=='\''))

tooManyErrors :: Parser TeXError
tooManyErrors = "That makes 100 errors; please try again."
             *> return TooManyErrors

dimentionTooLarge :: Parser TeXError
dimentionTooLarge = "Dimension too large."
                 *> return DimensionTooLarge

-- line 8075 tex.web
paragraphEnded :: Parser TeXError
paragraphEnded = do
  _ <- "Paragraph ended before "
  _ <- takeTill isSpace
  _ <- toBeReadAgain
  _ <- line
  return ParagraphEnded

numberTooBig :: Parser TeXError
numberTooBig = "Number too big" *> return NumberTooBig

-- LaTeX errors

latexError :: Parser TeXError
latexError = LaTeXError <$> ("LaTeX Error: " *> restOfLine)

-- Pages

nPages :: Parser Int
nPages = "Output written on "
      *> skipWhile (/= '(') *> char '('
      *> decimal

-- Utilities

restOfLine :: Parser ByteString
restOfLine = takeTill (=='\n') <* char '\n'

