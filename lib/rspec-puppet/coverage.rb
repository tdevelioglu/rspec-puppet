require 'tmpdir'
require 'digest'
require 'json'
require 'fileutils'

unless defined?(RSpec::Core::NullReporter)
  module RSpec::Core
    class NullReporter
      def self.method_missing(*)
        # ignore
      end
      private_class_method :method_missing
    end
  end
end

module RSpec::Puppet
  class Coverage

    attr_accessor :filters

    class << self
      extend Forwardable
      def_delegators(:instance, :add, :cover!, :report!,
                     :filters, :add_filter, :add_from_catalog,
                     :results)

      attr_writer :instance

      def instance
        @instance ||= new
      end
    end

    def initialize
      @collection = {}
      @filters = ['Stage[main]', 'Class[Settings]', 'Class[main]', 'Node[default]']
    end

    def save_results
      slug = "#{Digest::MD5.hexdigest(Dir.pwd)}-#{Process.pid}"
      File.open(File.join(Dir.tmpdir, "rspec-puppet-filter-#{slug}"), 'w+') do |f|
        f.puts @filters.to_json
      end
      File.open(File.join(Dir.tmpdir, "rspec-puppet-coverage-#{slug}"), 'w+') do |f|
        f.puts @collection.to_json
      end
    end

    def merge_results
      pattern = File.join(Dir.tmpdir, "rspec-puppet-coverage-#{Digest::MD5.hexdigest(Dir.pwd)}-*")
      Dir[pattern].each do |result_file|
        load_results(result_file)
        FileUtils.rm(result_file)
      end
    end

    def merge_filters
      pattern = File.join(Dir.tmpdir, "rspec-puppet-filter-#{Digest::MD5.hexdigest(Dir.pwd)}-*")
      Dir[pattern].each do |result_file|
        load_filters(result_file)
        FileUtils.rm(result_file)
      end
    end

    def load_results(path)
      saved_results = JSON.parse(File.read(path))
      saved_results.each do |resource, data|
        add(resource)
        cover!(resource) if data['touched']
      end
    end

    def load_filters(path)
      saved_filters = JSON.parse(File.read(path))
      saved_filters.each do |resource|
        @filters << resource
        @collection.delete(resource) if @collection.key?(resource)
      end
    end

    def add(resource)
      if !exists?(resource) && !filtered?(resource)
        @collection[resource.to_s] = ResourceWrapper.new(resource)
      end
    end

    def add_filter(type, title)
      def capitalize_name(name)
        name.split('::').map { |subtitle| subtitle.capitalize }.join('::')
      end

      type = capitalize_name(type)
      if type == 'Class'
        title = capitalize_name(title)
      end

      @filters << "#{type}[#{title}]"
    end

    # add all resources from catalog declared in module test_module
    def add_from_catalog(catalog, test_module)
      coverable_resources = catalog.to_a.reject { |resource| !test_module.nil? && filter_resource?(resource, test_module) }
      coverable_resources.each do |resource|
        add(resource)
      end
    end

    def filtered?(resource)
      filters.include?(resource.to_s)
    end

    def cover!(resource)
      if !filtered?(resource) && (wrapper = find(resource))
        wrapper.touch!
      end
    end

    def report!(coverage_desired = nil)
      if parallel_tests?
        require 'parallel_tests'

        if ParallelTests.first_process?
          ParallelTests.wait_for_other_processes_to_finish
          run_report(coverage_desired)
        else
          save_results
        end
      else
        run_report(coverage_desired)
      end
    end

    def parallel_tests?
      !!ENV['TEST_ENV_NUMBER']
    end

    def run_report(coverage_desired = nil)
      if ENV['TEST_ENV_NUMBER']
        merge_filters
        merge_results
      end

      report = results

      coverage_test(coverage_desired, report)

      puts report[:text]
    end

    def coverage_test(coverage_desired, report)
      coverage_actual = report[:coverage]
      coverage_desired ||= 0

      if coverage_desired.is_a?(Numeric) && coverage_desired.to_f <= 100.00 && coverage_desired.to_f >= 0.0
        coverage_test = RSpec.describe("Code coverage")
        coverage_results = coverage_test.example("must cover at least #{coverage_desired}% of resources") do
          expect( coverage_actual.to_f ).to be >= coverage_desired.to_f
        end
        coverage_test.run(RSpec.configuration.reporter)

        # This is not available on RSpec 2.x
        if coverage_results.execution_result.respond_to?(:pending_message)
          coverage_results.execution_result.pending_message = report[:text]
        end
      else
        puts "The desired coverage must be 0 <= x <= 100, not '#{coverage_desired.inspect}'"
      end
    end

    def results
      report = {}

      @collection.delete_if { |name, _| filtered?(name) }

      report[:total] = @collection.size
      report[:touched] = @collection.count { |_, resource| resource.touched? }
      report[:untouched] = report[:total] - report[:touched]
      report[:coverage] = "%5.2f" % ((report[:touched].to_f / report[:total].to_f) * 100)

      report[:resources] = Hash[*@collection.map do |name, wrapper|
        [name, wrapper.to_hash]
      end.flatten]

      text = [
        "Total resources:   #{report[:total]}",
        "Touched resources: #{report[:touched]}",
        "Resource coverage: #{report[:coverage]}%",
      ]

      if report[:untouched] > 0
        text += ['', 'Untouched resources:']
        untouched_resources = report[:resources].reject { |_, r| r[:touched] }
        text += untouched_resources.map { |name, _| "  #{name}" }.sort
      end
      report[:text] = text.join("\n")

      report
    end

    private

    # Should this resource be excluded from coverage reports?
    #
    # The resource is not included in coverage reports if any of the conditions hold:
    #
    #   * The resource has been explicitly filtered out.
    #     * Examples: autogenerated resources such as 'Stage[main]'
    #   * The resource is a class but does not belong to the module under test.
    #     * Examples: Class dependencies included from a fixture module
    #   * The resource was declared in a file outside of the test module or site.pp
    #     * Examples: Resources declared in a dependency of this module.
    #
    # @param resource [Puppet::Resource] The resource that may be filtered
    # @param test_module [String] The name of the module under test
    # @return [true, false]
    def filter_resource?(resource, test_module)
      if @filters.include?(resource.to_s)
        return true
      end

      if resource.type == 'Class'
        module_name = resource.title.split('::').first.downcase
        if module_name != test_module
          return true
        end
      end

      if resource.file
        paths = module_paths(test_module)
        unless paths.any? { |path| resource.file.include?(path) }
          return true
        end
      end

      return false
    end

    # Find all paths that may contain testable resources for a module.
    #
    # @return [Array<String>]
    def module_paths(test_module)
      adapter = RSpec.configuration.adapter
      paths = adapter.modulepath.map do |dir|
        File.join(dir, test_module, 'manifests')
      end
      paths << adapter.manifest if adapter.manifest
      paths
    end

    def find(resource)
      @collection[resource.to_s]
    end

    def exists?(resource)
      !find(resource).nil?
    end

    class ResourceWrapper
      attr_reader :resource

      def initialize(resource = nil)
        @resource = resource
      end

      def to_s
        @resource.to_s
      end

      def to_hash
        {
          :touched => touched?,
        }
      end

      def to_json(opts)
        to_hash.to_json(opts)
      end

      def touch!
        @touched = true
      end

      def touched?
        !!@touched
      end
    end
  end
end
