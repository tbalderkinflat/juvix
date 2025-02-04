module Commands.Typecheck where

import Commands.Base
import Commands.Typecheck.Options

runCommand :: (Members '[Embed IO, TaggedLock, App] r) => TypecheckOptions -> Sem r ()
runCommand localOpts = do
  void (runPipeline (localOpts ^. typecheckInputFile) upToCoreTypecheck)
  say "Well done! It type checks"
