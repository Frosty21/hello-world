# frozen_string_literal: true
require "bundler/worker"
require "bundler/installer/gem_installer"

module Bundler
  class ParallelInstaller
    class SpecInstallation
      attr_accessor :spec, :name, :post_install_message, :state, :error
      def initialize(spec)
        @spec = spec
        @name = spec.name
        @state = :none
        @post_install_message = ""
        @error = nil
      end

      def installed?
        state == :installed
      end

      def enqueued?
        state == :enqueued
      end

      def failed?
        state == :failed
      end

      def installation_attempted?
        installed? || failed?
      end

      # Only true when spec in neither installed nor already enqueued
      def ready_to_enqueue?
        !enqueued? && !installation_attempted?
      end

      def has_post_install_message?
        !post_install_message.empty?
      end

      def ignorable_dependency?(dep)
        dep.type == :development || dep.name == @name
      end

      # Checks installed dependencies against spec's dependencies to make
      # sure needed dependencies have been installed.
      def dependencies_installed?(all_specs)
        installed_specs = all_specs.select(&:installed?).map(&:name)
        dependencies(all_specs.map(&:name)).all? {|d| installed_specs.include? d.name }
      end

      # Represents only the non-development dependencies, the ones that are
      # itself and are in the total list.
      def dependencies(all_spec_names)
        @dependencies ||= begin
          deps = all_dependencies.reject {|dep| ignorable_dependency? dep }
          missing = deps.reject {|dep| all_spec_names.include? dep.name }
          unless missing.empty?
            raise Bundler::LockfileError, "Your Gemfile.lock is corrupt. The following #{missing.size > 1 ? "gems are" : "gem is"} missing " \
                                "from the DEPENDENCIES section: '#{missing.map(&:name).join('\' \'')}'"
          end
          deps
        end
      end

      # Represents all dependencies
      def all_dependencies
        @spec.dependencies
      end
    end

    def self.call(*args)
      new(*args).call
    end

    # Returns max number of threads machine can handle with a min of 1
    def self.max_threads
      [Bundler.settings[:jobs].to_i - 1, 1].max
    end

    def initialize(installer, all_specs, size, standalone, force)
      @installer = installer
      @size = size
      @standalone = standalone
      @force = force
      @specs = all_specs.map {|s| SpecInstallation.new(s) }
    end

    def call
      enqueue_specs
      process_specs until @specs.all?(&:installed?) || @specs.any?(&:failed?)
      handle_error if @specs.any?(&:failed?)
      @specs
    ensure
      worker_pool && worker_pool.stop
    end

    def worker_pool
      @worker_pool ||= Bundler::Worker.new @size, "Parallel Installer", lambda { |spec_install, worker_num|
        gem_installer = Bundler::GemInstaller.new(
          spec_install.spec, @installer, @standalone, worker_num, @force
        )
        success, message = gem_installer.install_from_spec
        if success && !message.nil?
          spec_install.post_install_message = message
        elsif !success
          spec_install.state = :failed
          spec_install.error = message
        end
        spec_install
      }
    end

    # Dequeue a spec and save its post-install message and then enqueue the
    # remaining specs.
    # Some specs might've had to wait til this spec was installed to be
    # processed so the call to `enqueue_specs` is important after every
    # dequeue.
    def process_specs
      spec = worker_pool.deq
      spec.state = :installed unless spec.failed?
      enqueue_specs
    end

    def handle_error
      errors = @specs.select(&:failed?).map(&:error)
      if exception = errors.find {|e| e.is_a?(Bundler::BundlerError) }
        raise exception
      end
      raise Bundler::InstallError, errors.map(&:to_s).join("\n\n")
    end

    # Keys in the remains hash represent uninstalled gems specs.
    # We enqueue all gem specs that do not have any dependencies.
    # Later we call this lambda again to install specs that depended on
    # previously installed specifications. We continue until all specs
    # are installed.
    def enqueue_specs
      @specs.select(&:ready_to_enqueue?).each do |spec|
        if spec.dependencies_installed? @specs
          spec.state = :enqueued
          worker_pool.enq spec
        end
      end
    end
  end
end
