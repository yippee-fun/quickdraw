# frozen_string_literal: true

# Mutation testing, for `quickdraw mutate`: small changes to methods (mutants)
# that the tests covering them should notice. Mutator uses Prism, so it only
# runs in a throwaway process; everything else is core Ruby, since Subject,
# Mutant and Tracer run in workers too.
module Quickdraw::Mutation
	autoload :Subject, "quickdraw/mutation/subject"
	autoload :Mutant, "quickdraw/mutation/mutant"
	autoload :Tracer, "quickdraw/mutation/tracer"
	autoload :Mutator, "quickdraw/mutation/mutator"
	autoload :Runner, "quickdraw/mutation/runner"
	autoload :KillMatrix, "quickdraw/mutation/kill_matrix"
	autoload :Cache, "quickdraw/mutation/cache"
end
