# encoding: utf-8

module CarrierWave
  module Uploader
    module Versions
      extend ActiveSupport::Concern

      include CarrierWave::Uploader::Callbacks

      included do
        class_attribute :version_options, :versions, :version_names, :instance_reader => false, :instance_writer => false

        self.versions = {}
        self.version_names = []
        self.version_options = {}

        attr_accessor :parent_cache_id

        after :cache, :assign_parent_cache_id
        after :cache, :cache_versions!
        after :store, :store_versions!
        after :remove, :remove_versions!
        after :retrieve_from_cache, :retrieve_versions_from_cache!
        after :retrieve_from_store, :retrieve_versions_from_store!
      end

      module ClassMethods
        def generate_version(name, options = {})
          uploader = Class.new(self)
          const_set("Uploader#{uploader.object_id}".gsub('-', '_'), uploader)
          uploader.versions = {}

          # Version options live on the uploader itself to simplify option access
          uploader.version_options = options

          # Define the enable_processing method for versions so they get the
          # value from the parent class unless explicitly overwritten
          uploader.class_eval <<-RUBY, __FILE__, __LINE__ + 1
            def self.enable_processing(value=nil)
              self.enable_processing = value if value
              if !@enable_processing.nil?
                @enable_processing
              else
                superclass.enable_processing
              end
            end
          RUBY

          # Add the current version hash to class attribute :versions
          uploader.version_names += [name]

          # as the processors get the output from the previous processors as their
          # input we must not stack the processors here
          uploader.processors = uploader.processors.dup
          uploader.processors.clear

          uploader
        end

        ##
        # Adds a new version to this uploader
        #
        # === Parameters
        #
        # [name (#to_sym)] name of the version
        # [options (Hash)] optional options hash
        # [&block (Proc)] a block to eval on this version of the uploader
        #
        # === Examples
        #
        #     class MyUploader < CarrierWave::Uploader::Base
        #
        #       version :thumb do
        #         process :scale => [200, 200]
        #       end
        #
        #       version :preview, :if => :image? do
        #         process :scale => [200, 200]
        #       end
        #
        #     end
        #
        def version(name, options = {}, &block)
          name = name.to_sym
          unless versions[name]
            self.versions = versions.merge(name => { :uploader => generate_version(name, options) })

            class_eval <<-RUBY
              def #{name}
                versions[:#{name}]
              end
            RUBY
          end
          versions[name][:uploader].class_eval(&block) if block
          versions[name]
        end

        def recursively_apply_block_to_versions(&block)
          versions.each do |name, version|
            version[:uploader].class_eval(&block)
            version[:uploader].recursively_apply_block_to_versions(&block)
          end
        end
      end # ClassMethods

      ##
      # Returns a hash mapping the name of each version of the uploader to an instance of it
      #
      # === Returns
      #
      # [Hash{Symbol => CarrierWave::Uploader}] a list of uploader instances
      #
      def versions
        return @versions if @versions
        @versions = {}
        self.class.versions.each do |name, version|
          @versions[name] = version[:uploader].new(model, mounted_as)
        end
        add_dynamic_versions(@versions)
        @versions
      end

      ##
      # Access this uploader's version options
      ##
      def version_options
        self.class.version_options
      end

      ##
      # Cache instantiated dynamic uploader classes
      ##
      def dynamic_version_classes
        @dynamic_version_classes ||= {}
      end

      ##
      # Cache instantiated dynamic uploaders
      ##
      def dynamic_versions
        @dynamic_versions ||= {}
      end

      ##
      # Override this to add your own dynamic versions to the uploader, probably
      # based on the model it holds.
      #
      # === Example
      #
      # def add_dynamic_versions(versions)
      #   if self.class.version_names.blank?
      #     model.scaled_version_definitions.each do |definition|
      #       versions[definition.name.to_sym] = add_dynamic_version(definition.name, :if => proc { some_condition }) { process :resize_to_fit => definition.resize_to_fit }
      #     end
      #   end
      # end
      ##
      def add_dynamic_versions(versions)
      end

      ##
      # Add a dynamic version. Works identically to the class method of creating versions.
      # Use within add_dynamic_versions.
      #
      # === Returns
      #
      # An instance of a CarrierWave::Uploader built for the dynamic version
      ##
      def version(name, options = {}, &block)
        name = name.to_sym

        if !dynamic_version_classes[name]
          dynamic_version_classes[name] = self.class.generate_version(name, options, &block)
          dynamic_version_classes[name].class_eval(&block) if block
        end

        # Create the instance of the version class and the accessor method for that version
        if !dynamic_versions[name]
          dynamic_versions[name] = dynamic_version_classes[name].new(model, mounted_as)

          instance_eval <<-RB
            def #{name}
              versions[:#{name}]
            end
          RB
        end

        dynamic_versions[name]
      end

      ##
      # === Returns
      #
      # [String] the name of this version of the uploader
      #
      def version_name
        self.class.version_names.join('_').to_sym unless self.class.version_names.blank?
      end

      ##
      # When given a version name as a parameter, will return the url for that version
      # This also works with nested versions.
      # When given a query hash as a parameter, will return the url with signature that contains query params
      # Query hash only works with AWS (S3 storage).
      #
      # === Example
      #
      #     my_uploader.url                 # => /path/to/my/uploader.gif
      #     my_uploader.url(:thumb)         # => /path/to/my/thumb_uploader.gif
      #     my_uploader.url(:thumb, :small) # => /path/to/my/thumb_small_uploader.gif
      #     my_uploader.url(:query => {"response-content-disposition" => "attachment"})
      #     my_uploader.url(:version, :sub_version, :query => {"response-content-disposition" => "attachment"})
      #
      # === Parameters
      #
      # [*args (Symbol)] any number of versions
      # OR/AND
      # [Hash] query params
      #
      # === Returns
      #
      # [String] the location where this file is accessible via a url
      #
      def url(*args)
        if (version = args.first) && version.respond_to?(:to_sym)
          raise ArgumentError, "Version #{version} doesn't exist!" if versions[version.to_sym].nil?
          # recursively proxy to version
          versions[version.to_sym].url(*args[1..-1])
        elsif args.first
          super(args.first)
        else
          super
        end
      end

      ##
      # Recreate versions and reprocess them. This can be used to recreate
      # versions if their parameters somehow have changed.
      #
      def recreate_versions!(*versions)
        # Some files could possibly not be stored on the local disk. This
        # doesn't play nicely with processing. Make sure that we're only
        # processing a cached file
        #
        # The call to store! will trigger the necessary callbacks to both
        # process this version and all sub-versions
        if versions.any?
          file = sanitized_file if !cached?
          store_versions!(file, versions)
        else
          cache! if !cached?
          store!
        end
      end

    private
      def assign_parent_cache_id(file)
        active_versions.each do |name, uploader|
          uploader.parent_cache_id = @cache_id
        end
      end

      def active_versions
        versions.select do |name, uploader|
          condition = uploader.version_options[:if]
          if(condition)
            if(condition.respond_to?(:call))
              condition.call(self, :version => name, :file => file)
            else
              send(condition, file)
            end
          else
            true
          end
        end
      end

      def full_filename(for_file)
        [version_name, super(for_file)].compact.join('_')
      end

      def full_original_filename
        [version_name, super].compact.join('_')
      end

      def cache_versions!(new_file)
        # We might have processed the new_file argument after the callbacks were
        # initialized, so get the actual file based off of the current state of
        # our file
        processed_parent = SanitizedFile.new :tempfile => self.file,
          :filename => new_file.original_filename

        active_versions.each do |name, v|
          next if v.cached?

          v.send(:cache_id=, cache_id)
          # If option :from_version is present, create cache using cached file from
          # version indicated
          if v.version_options && v.version_options[:from_version]
            # Maybe the reference version has not been cached yet
            unless versions[v.version_options[:from_version]].cached?
              versions[v.version_options[:from_version]].cache!(processed_parent)
            end
            processed_version = SanitizedFile.new :tempfile => versions[v.version_options[:from_version]],
              :filename => new_file.original_filename
            v.cache!(processed_version)
          else
            v.cache!(processed_parent)
          end
        end
      end

      def store_versions!(new_file, versions=nil)
        if versions
          versions.each { |v| Hash[active_versions][v].store!(new_file) }
        else
          active_versions.each { |name, v| v.store!(new_file) }
        end
      end

      def remove_versions!
        versions.each { |name, v| v.remove! }
      end

      def retrieve_versions_from_cache!(cache_name)
        versions.each { |name, v| v.retrieve_from_cache!(cache_name) }
      end

      def retrieve_versions_from_store!(identifier)
        versions.each { |name, v| v.retrieve_from_store!(identifier) }
      end

    end # Versions
  end # Uploader
end # CarrierWave
