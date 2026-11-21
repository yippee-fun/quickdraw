# frozen_string_literal: true

# Seeds `rand` for a test, but not until something reads the default random
# number generator, since seeding it takes over a microsecond and few tests
# read it. Every method in core Ruby that reads it is wrapped to seed it first.
# Only on CRuby, the one Ruby whose readers are known. Others seed at once.
#
# Runs alongside user code, so it must only use core Ruby.
module Quickdraw::Seed
	extend self

	LAZY = RUBY_ENGINE == "ruby"

	# The wrappers below wrap this one too.
	SRAND = ::Random.method(:srand)

	@mutex = Thread::Mutex.new
	@pending = nil

	attr_reader :pending

	# Seeds `rand` with `seed` when it's next read.
	def later(seed)
		if @installed
			# Locked, so a thread the last test left seeding can't clear this one.
			@mutex.synchronize { @pending = seed }
		else
			SRAND.call(seed)
		end
	end

	def now
		# Each Ractor has its own generator, which Quickdraw doesn't seed.
		return unless ::Ractor.current.equal?(::Ractor.main)

		@mutex.synchronize { sow }
	rescue ThreadError
		# A signal handler can't lock.
		sow
	end

	# Ruby gives a new process a generator with a seed of its own.
	def forget
		@pending = nil
	end

	def install
		return if @installed || !LAZY
		# Nothing can be prepended to a frozen class.
		return if [Kernel, Kernel.singleton_class, ::Random.singleton_class, ::Array, Process.singleton_class].any?(&:frozen?)

		Kernel.prepend(PrivateRand)
		Kernel.singleton_class.prepend(Rand)
		::Random.singleton_class.prepend(Rand, Generator)
		::Array.prepend(Shuffle)
		Process.singleton_class.prepend(Fork)
		@installed = true
	end

	private def sow
		return unless (seed = @pending)

		SRAND.call(seed)
		@pending = nil
	end

	module Rand
		def rand(...)
			Quickdraw::Seed.now if Quickdraw::Seed.pending
			super
		end

		# Returns the last seed.
		def srand(...)
			Quickdraw::Seed.now if Quickdraw::Seed.pending
			super
		end
	end

	module PrivateRand
		private def rand(...)
			Quickdraw::Seed.now if Quickdraw::Seed.pending
			super
		end

		private def srand(...)
			Quickdraw::Seed.now if Quickdraw::Seed.pending
			super
		end
	end

	# What Random::Formatter adds to Random reads it through these.
	module Generator
		def random_number(...)
			Quickdraw::Seed.now if Quickdraw::Seed.pending
			super
		end

		def bytes(...)
			Quickdraw::Seed.now if Quickdraw::Seed.pending
			super
		end

		def seed
			Quickdraw::Seed.now if Quickdraw::Seed.pending
			super
		end
	end

	module Shuffle
		def shuffle(...)
			Quickdraw::Seed.now if Quickdraw::Seed.pending
			super
		end

		def shuffle!(...)
			Quickdraw::Seed.now if Quickdraw::Seed.pending
			super
		end

		def sample(...)
			Quickdraw::Seed.now if Quickdraw::Seed.pending
			super
		end
	end

	module Fork
		def _fork
			pid = super
			Quickdraw::Seed.forget if pid == 0
			pid
		end

		# Forks without _fork.
		def daemon(...)
			super.tap { Quickdraw::Seed.forget }
		end
	end
end
