{-# LANGUAGE Arrows #-}

{- 
ParseSyntaxFiles.hs processes a directory containing Kate
XML syntax highlighting definitions.  For each xml file in
the directory, it creates a syntax highlighting parser

Text/Highlighting/Kate/Syntax/(name).hs.

Finally, it creates a module

Text/Highlighting/Kate/Syntax.hs with a wrapper around

all these modules.

Usage:  runghc ParseSyntaxFiles.hs xml

Requires HXT.
-}

module Main where

import Text.XML.HXT.Core
import Control.Arrow
import Control.Arrow.ArrowList
import Control.Monad (liftM)
import Data.List
import Data.Maybe
import Data.Char (toUpper, toLower, isAlphaNum)
import qualified Data.Map as Map
import System.Directory
import System.Environment
import System.Exit
import System.FilePath
import Text.PrettyPrint
import Text.Printf (printf)
import Data.Char (ord)
import Text.Highlighting.Kate.Definitions
import qualified Data.ByteString as B
import Data.ByteString.UTF8 (fromString, toString)

data SyntaxDefinition =
  SyntaxDefinition { synLanguage      :: String
                   , synAuthor        :: String
                   , synVersion       :: String
                   , synLicense       :: String
                   , synExtensions    :: String
                   , synCaseSensitive :: Bool
                   , synLists         :: [(String, [String])]
                   , synContexts      :: [SyntaxContext]
                   , synItemDatas     :: [(String, String)]
                   , synKeywordAttr   :: SyntaxKeywordAttr
                   } deriving (Read, Show)

data SyntaxKeywordAttr =
  SyntaxKeywordAttr  { keywordCaseSensitive   :: Bool
                     , keywordDelims          :: [Char]
                     } deriving (Read, Show)

data SyntaxContext = 
  SyntaxContext { contName               :: String
                , contAttribute          :: String
                , contLineEndContext     :: String
                , contLineBeginContext   :: String
                , contFallthrough        :: Bool
                , contFallthroughContext :: String
                , contDynamic            :: Bool
                , contParsers            :: [SyntaxParser] 
                } deriving (Read, Show)

data SyntaxParser =
  SyntaxParser { parserType              :: String
               , parserAttribute         :: String
               , parserContext           :: String
               , parserLookAhead         :: Bool
               , parserIncludeAttrib     :: Bool
               , parserFirstNonSpace     :: Bool
               , parserColumn            :: Maybe Int
               , parserDynamic           :: Bool
               , parserString            :: String -- could be a regex
               , parserChar              :: Char
               , parserChar1             :: Char
               , parserChildren          :: [SyntaxParser]
               } deriving (Read, Show)

-- | Converts a list of files (ending in .xml) and directories containing .xml files
-- into a list of .xml files.
argFiles :: [String] -> IO [String]
argFiles [] = error "Specify paths of xml files and/or directories containing xml syntax files."
argFiles args = do
  let isXmlFile x = isSuffixOf ".xml" x
  let (files, dirs) = partition isXmlFile args
  dirContents <- mapM (\dir -> getDirectoryContents dir >>= return . map (combine dir) . filter isXmlFile) dirs
  return $ nub (files ++ concat dirContents)


libraryPath = joinPath ["Text", "Highlighting", "Kate"]
destDir = joinPath [libraryPath, "Syntax"]

main :: IO ()
main = do
  files <- getArgs >>= argFiles
  destDirExists <- doesDirectoryExist destDir
  if destDirExists
     then return ()
     else createDirectory destDir 
  mapM_ processOneFile files
  let syntaxFile = combine libraryPath (addExtension "Syntax" "hs")
  putStrLn $ "Writing " ++ syntaxFile
  -- Get all syntax files, not only the newly generated ones.
  names <- getDirectoryContents destDir >>= return . sort . map dropExtension . filter (isSuffixOf ".hs")
  let imports = unlines $ map (\name -> "import qualified Text.Highlighting.Kate.Syntax." ++ name ++ " as " ++ name) names 
  let cases = unlines $ map (\name -> show (map toLower name) ++ " -> " ++ name ++ ".highlight") names
  let languageExtensions = '[' :
        (intercalate ", " $ map (\name -> "(" ++ show name ++ ", " ++ name ++ ".syntaxExtensions)") names) ++ "]"
  syntaxFileTemplate <- liftM toString $ B.readFile (syntaxFile <.> "in")
  let filledTemplate = fillTemplate 0 [("imports",imports),
                                       ("languages",show names),
                                       ("languageExtensions",languageExtensions),
                                       ("cases",cases)] syntaxFileTemplate
  B.writeFile syntaxFile $ fromString filledTemplate

processOneFile :: FilePath -> IO ()
processOneFile src = do
  [syntax] <- runX $ application src
  let name = nameFromPath src
  let outFile = joinPath [libraryPath, "Syntax", addExtension name "hs"]
  let includeLangs = nub $ filter (/= name) $ map (drop 2 . parserContext) $
        filter (\p -> (parserType p) == "IncludeRules" && "##" `isPrefixOf` (parserContext p)) $ 
        concatMap contParsers $ synContexts syntax
  let includeImports = map (("import qualified " ++) . langNameToModule) includeLangs
  putStrLn $ "Writing " ++ outFile
  B.writeFile outFile $ fromString $
           "{- This module was generated from data in the Kate syntax highlighting file " ++ (takeFileName src) ++ ", version " ++ 
           synVersion syntax ++ ",\n" ++
           "   by  " ++ synAuthor syntax ++ " -}\n\n" ++ 
           "module Text.Highlighting.Kate.Syntax." ++ name ++ " ( highlight, parseExpression, syntaxName, syntaxExtensions ) where\n\
           \import Text.Highlighting.Kate.Definitions\n\
           \import Text.Highlighting.Kate.Common\n" ++
           unlines includeImports ++ 
           "import Text.ParserCombinators.Parsec\n\
           \import Control.Monad (when)\n\
           \import Data.Map (fromList)\n\
           \import Data.Maybe (fromMaybe, maybeToList)\n\n" ++
           (if null (synLists syntax)
               then ""
               else "import qualified Data.Set as Set\n") ++
           render (mkParser syntax) ++ "\n"

mkParser :: SyntaxDefinition -> Doc
mkParser syntax = 
  let name = text "-- | Full name of language." $$
             text "syntaxName :: String" $$
             text ("syntaxName = " ++ show (synLanguage syntax))
      exts = text "-- | Filename extensions for this language." $$
             text "syntaxExtensions :: String" $$
             text ("syntaxExtensions = " ++ show (synExtensions syntax))
      shortFormOf "dsKeyword" = ["kw"]
      shortFormOf "dsDataType" = ["dt"] 
      shortFormOf "dsDecVal" = ["dv"]
      shortFormOf "dsBaseN" = ["bn"]
      shortFormOf "dsFloat" = ["fl"]
      shortFormOf "dsChar" = ["ch"]
      shortFormOf "dsString" = ["st"]
      shortFormOf "dsComment" = ["co"]
      shortFormOf "dsOthers" = ["ot"]
      shortFormOf "dsAlert" = ["al"]
      shortFormOf "dsFunction" = ["fu"]
      shortFormOf "dsRegionMarker" = ["re"]
      shortFormOf "dsError" = ["er"]
      shortFormOf _ = []
      styles = text ("styles = " ++ (show [(typ, shortsty) | (typ, sty) <- synItemDatas syntax, shortsty <- shortFormOf sty]))
      withAttr = text "withAttribute attr txt = do" $$ (nest 2 $
                   text "when (null txt) $ fail \"Parser matched no text\"" $$
                   text "let labs = attr : maybeToList (lookup attr styles)" $$
                   text "st <- getState" $$
                   text "let oldCharsParsed = synStCharsParsedInLine st" $$
                   text "let prevchar = if null txt then '\\n' else last txt" $$
                   text "updateState $ \\st -> st { synStCharsParsedInLine = oldCharsParsed + length txt, synStPrevChar = prevchar } " $$
                   text "return (labs, txt)")
      parseExpressionInternal = text "parseExpressionInternal = do" $$ (nest 2 $ 
                                  text "context <- currentContext" $$
                                  text "parseRules context <|> (pDefault >>= withAttribute (fromMaybe \"\" $ lookup context defaultAttributes))")
      parseExpression = text "-- | Parse an expression using appropriate local context." $$
                        text "parseExpression :: GenParser Char SyntaxState LabeledSource" $$
                        text "parseExpression = do" $$ (nest 2 $ 
                          text "st <- getState" $$
                          text "let oldLang = synStLanguage st" $$
                          text ("setState $ st { synStLanguage = " ++ show (synLanguage syntax) ++ " }") $$
                          text ("context <- currentContext <|> (pushContext " ++ show (contName $ head $ synContexts syntax) ++
                                " >> currentContext)") $$
                          text "result <- parseRules context" $$
                          text "updateState $ \\st -> st { synStLanguage = oldLang }" $$
                          text "return result")
      defaultAttributes = text $ "defaultAttributes = " ++ (show $ map (\cont -> (contName cont, contAttribute cont)) $ synContexts syntax)
      -- Note: lineBeginContexts seems not to be used in any of the xml files
      -- lineBeginContexts = 
      --   text $ "lineBeginContexts = " ++ (show $ map (\cont -> (contName cont, contLineBeginContext cont)) $ synContexts syntax)
      startingContext = head (synContexts syntax)
      contextCatchAll = text $ "parseRules x = fail $ \"Unknown context\" ++ x"
      contexts = map (mkRules syntax) $ synContexts syntax
      initialContextStack = Map.fromList [(synLanguage syntax, [contName startingContext])]
      startingState = SyntaxState { synStContexts = initialContextStack
                                  , synStLanguage = synLanguage syntax
                                  , synStCurrentLine = ""
                                  , synStCharsParsedInLine = 0
                                  , synStPrevChar = '\n'
                                  , synStCaseSensitive = synCaseSensitive syntax
                                  , synStKeywordCaseSensitive = keywordCaseSensitive (synKeywordAttr syntax)
                                  , synStCaptures = [] }
      initState = text $ "startingState = " ++ show startingState
      sourceLineParser = text "parseSourceLine = manyTill parseExpressionInternal pEndLine"
      mainParser = text "parseSource = do " $$  
                   (nest 2 $ text "lineContents <- lookAhead wholeLine" $$
                             text "updateState $ \\st -> st { synStCurrentLine = lineContents }" $$
                             -- text "context <- currentContext" $$
                             -- text "pushContext (fromMaybe \"#stay\" $ lookup context lineBeginContexts)" $$
                             text "result <- manyTill parseSourceLine eof" $$
                             text "return $ map normalizeHighlighting result")
      mainFunction = text $ "-- | Highlight source code using this syntax definition.\n\
                            \highlight :: String -> Either String [SourceLine]\n\
                            \highlight input =\n\
                            \  case runParser parseSource startingState \"source\" input of\n\
                            \    Left err     -> Left $ show err\n\
                            \    Right result -> Right result"
      endLineParser = text "pEndLine = do" $$
                      (nest 2 $ text "lookAhead $ newline <|> (eof >> return '\\n')" $$
                                text "context <- currentContext" $$
                                text "case context of" $$
                                (nest 2 $ (vcat $ map (\cont -> text (show $ contName cont) <> text " -> " <> 
                                            switchContext (contLineEndContext cont) <>
                                            if "#pop" `isPrefixOf` (contLineEndContext cont)
                                               then text " >> pEndLine"
                                               else text " >> pHandleEndLine") $ synContexts syntax) $$
                                          (text $ "_ -> pHandleEndLine")))
                                {- text "pushContext (fromMaybe \"#stay\" $ lookup context lineBeginContexts)" $$ -}
      -- we use 'words "blah blah2 blah3"' to keep ghc from inlining the list, which makes compiling take a long time
      listDef (n, list) = text $ listName n ++ " = Set.fromList $ words $ " ++
                               show (if keywordCaseSensitive (synKeywordAttr syntax)
                                        then unwords list
                                        else map toLower (unwords list))
      lists = vcat $ map listDef $ synLists syntax
      regexDef re = text $ compiledRegexName re ++ " = compileRegex " ++ show re
      regexes = vcat $ map regexDef $ nub $ [parserString x | x <- concatMap contParsers (synContexts syntax),
                                                              parserType x == "RegExpr", parserDynamic x == False]
  in  vcat $ intersperse (text "") $ [name, exts, mainFunction, parseExpression, mainParser, initState, sourceLineParser, 
                                      endLineParser, withAttr, styles, parseExpressionInternal, lists, regexes,
                                      defaultAttributes {- , lineBeginContexts -}] ++ contexts ++ [contextCatchAll]

mkAlternatives :: [Doc] -> Doc
mkAlternatives docs = 
  let contents = vcat $ intersperse (text "<|>") docs
  in  if length docs > 1
         then char '(' <> contents <> char ')'
         else contents

mkRules :: SyntaxDefinition -> SyntaxContext -> Doc
mkRules syntax context =
  let fallthroughParser = if contFallthrough context
                             then [parens (switchContext (contFallthroughContext context) <> 
                                   text " >> return ([], \"\")")]
                             else []
  in  text ("parseRules " ++ show (contName context) ++ " = ") $$ 
      if null (contParsers context) && null fallthroughParser
         then nest 2 (text "pzero")
         else nest 2 $ (text "do (attr, result) <- " <> 
                       (mkAlternatives $ (map (mkSyntaxParser syntax context) $ contParsers context) ++ fallthroughParser)) $$
                       text ("   return (attr, result)")

mkSyntaxParser :: SyntaxDefinition -> SyntaxContext -> SyntaxParser -> Doc
mkSyntaxParser syntax context parser = 
  let mainParser = text $ case parserType parser of
            "DetectChar"       -> "pDetectChar " ++ show (parserDynamic parser) ++ " " ++ show (parserChar parser)
            "Detect2Chars"     -> "pDetect2Chars " ++ show (parserDynamic parser) ++ " " ++ 
                                    show (parserChar parser) ++ " " ++ show (parserChar1 parser)
            "AnyChar"          -> "pAnyChar " ++ show (parserString parser)
            "StringDetect"     -> "pString " ++ show (parserDynamic parser) ++ " " ++ show (parserString parser) 
            "RegExpr"          -> if parserDynamic parser
                                     then "pRegExprDynamic " ++ show (parserString parser)
                                     else "pRegExpr " ++ compiledRegexName (parserString parser)
            "keyword"          -> "pKeyword " ++ show (keywordDelims $ synKeywordAttr syntax) ++ " " ++ list
                                     where list = case lookup string (synLists syntax) of
                                                   Just _   -> listName string
                                                   Nothing  -> "Set.empty"
                                           string = parserString parser
            "Int"              -> "pInt"
            "Float"            -> "pFloat"
            "HlCOct"           -> "pHlCOct"
            "HlCHex"           -> "pHlCHex"
            "HlCStringChar"    -> "pHlCStringChar"
            "HlCChar"          -> "pHlCChar"
            "RangeDetect"      -> "pRangeDetect " ++ show (parserChar parser) ++ " " ++ show (parserChar1 parser)
            "LineContinue"     -> "pLineContinue"
            "IncludeRules"     -> case parserContext parser of
                                      ('#':'#':xs) -> langNameToModule xs ++ ".parseExpression" ++
                                                      if parserIncludeAttrib parser || null (parserAttribute parser)
                                                         then ""
                                                         else " >>= ((withAttribute " ++ show (parserAttribute parser) ++ ") . snd)" 
                                      xs           -> "parseRules " ++ show xs
            "DetectSpaces"     -> "pDetectSpaces"
            "DetectIdentifier" -> "pDetectIdentifier"
            _                  -> "pUnimplemented"
      parserDoc = char '(' <>
                  (case (parserColumn parser) of
                       Just c  -> text $ "pColumn " ++ show c ++ " >> "
                       _       -> empty) <>
                  (if parserFirstNonSpace parser
                     then text "pFirstNonSpace >> "
                     else empty) <>
                  if parserType parser == "IncludeRules"
                     then mainParser <> char ')'
                     else (if parserLookAhead parser
                             then text "lookAhead (" <> mainParser <> text ") >> return ([],\"\") " 
                             else mainParser <> text " >>= withAttribute " <> 
                                  text (if null (parserAttribute parser)
                                           then show (contAttribute context)
                                           else show (parserAttribute parser))) <> 
                          char ')' <>
                          (if parserContext parser `elem` ["", "#stay"]
                              then empty 
                              else text " >>~ " <> switchContext (parserContext parser))
      childParsers = parserChildren parser
  in  char '(' <>
      (if null childParsers
          then parserDoc
          else text "withChildren " <> parserDoc <> char ' ' <> (mkAlternatives $ map (mkSyntaxParser syntax context) childParsers)) <>
      char ')'

switchContext next =
  case next of
     x | "#pop" `isPrefixOf` x -> char '(' <>
          text (concat $ intersperse " >> " $ replicate (length (filter (=='#') x)) "popContext") <> char ')'
     "#stay" -> text "return ()"
     x -> text ("pushContext " ++ show x) 

langNameToModule str =  "Text.Highlighting.Kate.Syntax." ++
  case str of
    "Alerts" -> "Alert"
    "Alerts_indent" -> "Alert_indent"
    "C++" -> "Cpp"
    "CSS" -> "Css"
    "Doxygen" -> "Doxygen"
    "HTML" -> "Html"
    "Javadoc" -> "Javadoc"
    "JavaScript" -> "Javascript"
    "SQL (MySQL)" -> "SqlMysql"
    "DoxygenLua" -> "Doxygenlua"
    x -> x

listName :: String -> String
listName n = "list_" ++ normalize n

compiledRegexName :: String -> String
compiledRegexName n = "regex_" ++ normalize n

normalize :: String -> String
normalize "" = ""
normalize (x:xs) | isAlphaNum x = x : normalize xs 
normalize (' ':xs)              = '_':normalize xs
normalize (x:xs)                = printf "'%2x" (ord x) ++ normalize xs

capitalize :: String -> String
capitalize (x:xs) = toUpper x : xs
capitalize [] = []

nameFromPath :: FilePath -> String
nameFromPath = concat . map capitalize . words . 
               (map (\c -> if c == '-' then ' ' else c)) . takeFileName . 
               dropExtension

application :: String -> IOSArrow b SyntaxDefinition
application src
    = readDocument [withValidate no, withInputEncoding utf8] src
      >>>
      multi (hasName "language")
      >>>
      extractSyntaxDefinition

extractSyntaxDefinition :: IOSArrow XmlTree SyntaxDefinition
extractSyntaxDefinition =  proc x -> do
                             lang <- getAttrValue "name" -< x
                             author <- getAttrValue "author" -< x
                             version <- getAttrValue "version" -< x
                             license <- getAttrValue "license" -< x
                             sources <- getAttrValue "extensions" -< x
                             caseSensitive <- getAttrValue "casesensitive" -< x
                             itemdatas <- getItemDatas -< x
                             lists <- getLists -< x
                             contexts <- getContexts -< x
                             keywordAttr <- getKeywordAttrs -< x
                             returnA -< SyntaxDefinition { synLanguage      = lang 
                                                         , synAuthor        = author
                                                         , synVersion       = version
                                                         , synLicense       = license 
                                                         , synExtensions    = sources
                                                         , synCaseSensitive = vBool True caseSensitive
                                                         , synLists         = lists
                                                         , synContexts      = contexts 
                                                         , synItemDatas     = itemdatas
                                                         , synKeywordAttr   = if null keywordAttr
                                                                                 then defaultKeywordAttr
                                                                                 else head keywordAttr }

getItemDatas :: IOSArrow XmlTree [(String,String)]
getItemDatas = multi (hasName "itemDatas")
               >>>
               (listA $ getChildren
                       >>>
                       hasName "itemData"
                       >>>
                       getAttrValue "name" &&& getAttrValue "defStyleNum")

getLists :: IOSArrow XmlTree [(String, [String])]
getLists = listA $ multi (hasName "list")
                   >>> 
                   getAttrValue "name" &&& getListContents

getListContents :: IOSArrow XmlTree [String]
getListContents = listA $ getChildren
                          >>> 
                          hasName "item"
                          >>>
                          getChildren
                          >>>
                          getText
                          >>>
                          arr stripWhitespace

getContexts :: IOSArrow XmlTree [SyntaxContext]
getContexts = listA $   multi (hasName "context")
                        >>>
                        proc x -> do
                          name <- getAttrValue "name" -< x
                          attribute <- getAttrValue "attribute" -< x
                          lineEndContext <- getAttrValue "lineEndContext" -< x
                          lineBeginContext <- getAttrValue "lineBeginContext" -< x
                          fallthrough <- getAttrValue "fallthrough" -< x
                          fallthroughContext <- getAttrValue "fallthroughContext" -< x
                          dynamic <- getAttrValue "dynamic" -< x
                          parsers <- getParsers -< x
                          returnA -< SyntaxContext 
                                           { contName = name
                                           , contAttribute = attribute
                                           , contLineEndContext = if null lineEndContext then "#stay" else lineEndContext
                                           , contLineBeginContext = if null lineBeginContext then "#stay" else lineBeginContext
                                           , contFallthrough = vBool False fallthrough
                                           , contFallthroughContext = if null fallthroughContext then "#stay" else fallthroughContext
                                           , contDynamic = vBool False dynamic
                                           , contParsers = parsers }

getParsers :: IOSArrow XmlTree [SyntaxParser]
getParsers = listA $ getChildren 
                     >>>
                     proc x -> do
                       name <- getName -< x
                       attribute <- getAttrValue "attribute" -< x
                       context <- getAttrValue "context" -< x
                       char0 <- getAttrValue "char" -< x
                       char1 <- getAttrValue "char1" -< x
                       str <- getAttrValue "String" -< x
                       includeAttrib <- getAttrValue "includeAttrib" -< x
                       lookahead <- getAttrValue "lookAhead" -< x
                       firstNonSpace <- getAttrValue "firstNonSpace" -< x
                       column <- getAttrValue "column" -< x
                       dynamic <- getAttrValue "dynamic" -< x
                       children <- getParsers -< x
                       let tildeRegex = name == "RegExpr" && length str > 0 && head str == '^'
                       returnA -< SyntaxParser 
                                    { parserType = name
                                    , parserAttribute = attribute
                                    , parserContext = context
                                    , parserLookAhead = vBool False lookahead
                                    , parserIncludeAttrib = vBool False includeAttrib
                                    , parserFirstNonSpace = vBool False firstNonSpace
                                    , parserColumn = if tildeRegex
                                                        then Just 0
                                                        else if null column 
                                                                then Nothing 
                                                                else Just (read column)
                                    , parserDynamic = vBool False dynamic
                                    , parserString = if tildeRegex then drop 1 str else str
                                    , parserChar = if length char0 == 1 then head char0 else '*'
                                    , parserChar1 = if length char1 == 1 then head char1 else '*'
                                    , parserChildren = children }

getKeywordAttrs :: IOSArrow XmlTree [SyntaxKeywordAttr]
getKeywordAttrs = listA $ multi $ hasName "keywords"
                                  >>>
                                  proc x -> do
                                    caseSensitive <- getAttrValue "casesensitive" -< x
                                    weakDelim <- getAttrValue "weakDeliminator" -< x
                                    additionalDelim <- getAttrValue "additionalDeliminator" -< x
                                    returnA -< SyntaxKeywordAttr 
                                                      { keywordCaseSensitive = vBool True caseSensitive
                                                      , keywordDelims = (standardDelims ++ additionalDelim) \\ weakDelim }

standardDelims = " \n\t.():!+,-<=>%&*/;?[]^{|}~\\" 

defaultKeywordAttr = SyntaxKeywordAttr { keywordCaseSensitive = True
                                       , keywordDelims = standardDelims }

stripWhitespaceLeft = dropWhile isWhitespace 
isWhitespace x = elem x [' ', '\t', '\n']
stripWhitespace = reverse . stripWhitespaceLeft . reverse . stripWhitespaceLeft

vBool :: Bool -> String -> Bool
vBool defaultVal value = case value of
                           z | z `elem` ["true","yes","1"] -> True
                           z | z `elem` ["false","no","0"] -> False
                           _ -> defaultVal

-- | Fill template.  The template variables in the source text are
-- surrounded by @'s: e.g., @myvar@.
fillTemplate :: Int -> [(String,String)] -> String -> String
fillTemplate _ _ [] = []
fillTemplate _ [] lst = lst
fillTemplate n subs ('\n':xs) = '\n' : fillTemplate 0 subs xs
fillTemplate n subs ('@':xs) =
  let (pref, suff) = break (=='@') xs
  in  if length pref > 0 && all isAlphaNum pref && length suff > 0
         then case lookup pref subs of
                    Just v  -> intercalate ('\n':replicate n ' ') (lines v) ++
                                 fillTemplate (n + length v) subs (tail suff)
                    Nothing -> '@' : fillTemplate (n+1) subs xs
         else '@' : fillTemplate (n+1) subs xs
fillTemplate n subs (x:xs) = x : fillTemplate (n+1) subs xs

