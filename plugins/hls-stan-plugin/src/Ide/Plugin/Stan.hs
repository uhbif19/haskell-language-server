module Ide.Plugin.Stan (descriptor) where

import           Control.DeepSeq                (NFData)
import           Control.Monad                  (void)
import           Control.Monad.IO.Class         (liftIO)
import           Control.Monad.Trans.Class      (lift)
import           Control.Monad.Trans.Maybe      (MaybeT (MaybeT), runMaybeT)
import           Data.Foldable                  (toList)
import qualified Data.HashMap.Strict            as HM
import           Data.Hashable                  (Hashable)
import qualified Data.Map                       as Map
import           Data.Maybe                     (fromJust, mapMaybe)
import qualified Data.Text                      as T
import           Data.Typeable                  (Typeable, cast)
import           Development.IDE                (Action, FileDiagnostic,
                                                 GetHieAst (..),
                                                 GetModSummaryWithoutTimestamps (..),
                                                 GhcSession (..), IdeState,
                                                 NormalizedFilePath,
                                                 Pretty (..), Recorder,
                                                 RuleResult, Rules,
                                                 ShowDiagnostic (..),
                                                 TypeCheck (..), WithPriority,
                                                 action, cmapWithPrio, define,
                                                 getFilesOfInterestUntracked,
                                                 hscEnv, msrModSummary,
                                                 tmrTypechecked, use, uses)
import           Development.IDE.Core.RuleTypes (HieAstResult (..))
import           Development.IDE.Core.Rules     (getSourceFileSource)
import qualified Development.IDE.Core.Shake     as Shake
import           Development.IDE.GHC.Compat     (HieASTs (HieASTs),
                                                 RealSrcSpan (..), mkHieFile',
                                                 mkRealSrcLoc, mkRealSrcSpan,
                                                 runHsc, srcSpanEndCol,
                                                 srcSpanEndLine,
                                                 srcSpanStartCol,
                                                 srcSpanStartLine, tcg_exports)
import           Development.IDE.GHC.Error      (realSrcSpanToRange)
import           GHC.Generics                   (Generic)
import           HieTypes                       (HieASTs, HieFile)
import           Ide.Types                      (PluginDescriptor (..),
                                                 PluginId,
                                                 defaultPluginDescriptor)
import qualified Language.LSP.Types             as LSP
import           Stan.Analysis                  (Analysis (..), runAnalysis)
import           Stan.Core.Id                   (Id (..))
import           Stan.Inspection                (Inspection (..))
import           Stan.Inspection.All            (inspectionsIds, inspectionsMap)
import           Stan.Observation               (Observation (..))

descriptor :: Recorder (WithPriority Log) -> PluginId -> PluginDescriptor IdeState
descriptor recorder plId = (defaultPluginDescriptor plId) {pluginRules = rules recorder}

newtype Log = LogShake Shake.Log deriving (Show)

instance Pretty Log where
  pretty = \case
    LogShake log -> pretty log

data GetStanDiagnostics = GetStanDiagnostics
  deriving (Eq, Show, Generic)

instance Hashable GetStanDiagnostics

instance NFData GetStanDiagnostics

type instance RuleResult GetStanDiagnostics = ()

rules :: Recorder (WithPriority Log) -> Rules ()
rules recorder = do
  define (cmapWithPrio LogShake recorder) $
    \GetStanDiagnostics file -> do
      hie <- fromJust <$> getHieFile file
      let enabledInspections = HM.fromList [(LSP.fromNormalizedFilePath file, inspectionsIds)]
      let analysis = runAnalysis Map.empty enabledInspections [] [hie]
      return (analysisToDiagnostics file analysis, Just ())

  action $ do
    files <- getFilesOfInterestUntracked
    void $ uses GetStanDiagnostics $ HM.keys files
  where
    analysisToDiagnostics :: NormalizedFilePath -> Analysis -> [FileDiagnostic]
    analysisToDiagnostics file = mapMaybe (observationToDianostic file) . toList . analysisObservations
    observationToDianostic :: NormalizedFilePath -> Observation -> Maybe FileDiagnostic
    observationToDianostic file (Observation {observationSrcSpan, observationInspectionId}) =
      do
        inspection <- HM.lookup observationInspectionId inspectionsMap
        let
          -- Looking similar to Stan CLI output
          message :: T.Text
          message =
            T.unlines $
              [ " ✲ Name:        " <> inspectionName inspection,
                " ✲ Description: " <> inspectionDescription inspection,
                "Possible solutions:"
              ]
                ++ map ("  - " <>) (inspectionSolution inspection)
        return ( file,
          ShowDiag,
          LSP.Diagnostic
            { _range = realSrcSpanToRange $ observationSrcSpan,
              _severity = Just LSP.DsHint,
              _code = Just (LSP.InR $ unId (inspectionId inspection)),
              _source = Just "stan",
              _message = message,
              _relatedInformation = Nothing,
              _tags = Nothing
            }
          )

getHieFile :: NormalizedFilePath -> Action (Maybe HieFile)
getHieFile nfp = runMaybeT $ do
  HAR {hieAst} <- MaybeT $ use GetHieAst nfp
  tmr <- MaybeT $ use TypeCheck nfp
  ghc <- MaybeT $ use GhcSession nfp
  msr <- MaybeT $ use GetModSummaryWithoutTimestamps nfp
  source <- lift $ getSourceFileSource nfp
  let exports = tcg_exports $ tmrTypechecked tmr
  typedAst <- MaybeT $ pure $ cast hieAst
  liftIO $ runHsc (hscEnv ghc) $ mkHieFile' (msrModSummary msr) exports typedAst source
