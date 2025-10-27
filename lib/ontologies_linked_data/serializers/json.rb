require 'multi_json'

module LinkedData
  module Serializers
    class JSON
      CONTEXTS = {}

      def self.serialize(obj, options = {})


        hash = obj.to_flex_hash(options) do |hash, hashed_obj|
          current_cls = hashed_obj.respond_to?(:klass) ? hashed_obj.klass : hashed_obj.class
          result_lang = self.get_languages(get_object_submission(hashed_obj), options[:lang])

          # Intentionally no OntoLex::LexicalConcept enrichment here: models/controllers handle it

          # Removed LexicalSense enrichment here to avoid duplication; models ensure fields.

          # Intentionally no OntoLex::Form enrichment here: models + controllers ensure parity

          # Intentionally no LexicalEntry relation backfill here: model to_hash provides IRIs

          # Intentionally no definition reshaping here: handled in LexicalConcept#to_hash

          # Add the id to json-ld attribute
          if current_cls.ancestors.include?(LinkedData::Hypermedia::Resource) && !current_cls.embedded? && hashed_obj.respond_to?(:id)
            prefixed_id = LinkedData::Models::Base.replace_url_id_to_prefix(hashed_obj.id)
            hash["@id"] = prefixed_id.to_s
          end

          # Add the type
          hash["@type"] = type(current_cls, hashed_obj) if hash["@id"]

          # Generate links
          # NOTE: If this logic changes, also change in xml.rb
          if generate_links?(options)
            links = LinkedData::Hypermedia.generate_links(hashed_obj)
            unless links.empty?
              hash["links"] = links
              hash["links"].merge!(generate_links_context(hashed_obj)) if generate_context?(options)
            end
          end

          # Generate context
          if current_cls.ancestors.include?(Goo::Base::Resource) && !current_cls.embedded?
            if generate_context?(options)
              context = generate_context(hashed_obj, hash.keys, options)
              hash.merge!(context)
            end
          end
          hash['@context']['@language'] = result_lang if hash['@context']

          # Do not leak submission on read_only structs
          hash.delete('submission') if hash.key?('submission')
          hash.delete(:submission) if hash.key?(:submission)
        end
        # Coerce any RDF objects (URI, Vocabulary terms) into plain strings to avoid
        # ActiveSupport JSON trying to introspect them (which triggers Goo's method_missing)
        begin
          hash = stringify_rdf_objects(hash)
        rescue StandardError
        end
        # Normalize keys to strings and merge duplicates from symbol/string collisions
        begin
          hash = normalize_keys_and_dedup(hash)
        rescue StandardError
        end
        MultiJson.dump(hash)
      end

      private

      def self.stringify_rdf_objects(obj)
        # Convert RDF::URI, RDF::Node, RDF::Vocabulary terms into strings recursively
        if defined?(RDF)
          return obj.to_s if obj.is_a?(RDF::URI) || obj.is_a?(RDF::Node)
          # Many RDF vocab terms respond to to_uri
          if !obj.is_a?(String) && obj.respond_to?(:to_uri)
            begin
              return obj.to_uri.to_s
            rescue StandardError
              # fall through
            end
          end
        end
        case obj
        when Array
          obj.map { |v| stringify_rdf_objects(v) }
        when Hash
          obj.each_with_object({}) do |(k, v), acc|
            acc[k] = stringify_rdf_objects(v)
          end
        else
          # Coerce any non-primitive, non-nil object to string to avoid ActiveSupport as_json introspection
          if obj.nil? || obj.is_a?(Numeric) || obj.is_a?(TrueClass) || obj.is_a?(FalseClass) || obj.is_a?(String)
            obj
          else
            begin
              obj.to_s
            rescue StandardError
              obj.inspect
            end
          end
        end
      end

      # Convert all hash keys to strings and merge duplicates caused by symbol/string collisions.
      # For arrays, keep order and de-duplicate values. For nested hashes, apply recursively.
      def self.normalize_keys_and_dedup(obj)
        case obj
        when Array
          obj.map { |v| normalize_keys_and_dedup(v) }
        when Hash
          acc = {}
          obj.each do |k, v|
            sk = k.to_s
            nv = normalize_keys_and_dedup(v)
            if acc.key?(sk)
              acc[sk] = merge_values(acc[sk], nv)
            else
              acc[sk] = nv
            end
          end
          acc
        else
          obj
        end
      end

      def self.merge_values(a, b)
        # If both are arrays, concatenate then uniq while preserving order
        if a.is_a?(Array) && b.is_a?(Array)
          seen = {}
          (a + b).each_with_object([]) do |e, arr|
            key = e.is_a?(Hash) ? e.hash : e
            next if seen[key]
            arr << e
            seen[key] = true
          end
        elsif a.is_a?(Hash) && b.is_a?(Hash)
          # Merge nested hashes recursively with string keys
          normalize_keys_and_dedup(a.merge(b) { |_, v1, v2| merge_values(v1, v2) })
        else
          # Prefer 'a' when present; do not overwrite empty arrays/strings with nil
          return a unless a.nil?
          b
        end
      end

      def self.get_object_submission(obj)
        # Prefer direct submission accessor when present (works for read_only structs)
        return obj.submission if obj.respond_to?(:submission) && !obj.submission.nil?
        # Otherwise, check class attributes for Resource instances
        obj.class.respond_to?(:attributes) && obj.class.attributes.include?(:submission) ? obj.submission : nil
      end

      def self.get_languages(submission, user_languages)

        if user_languages.eql?(:all) || user_languages.blank?
          if submission
            submission.bring(:naturalLanguage) if submission.bring?(:naturalLanguage)
            submission_languages_languages = get_submission_languages(submission.naturalLanguage)
          end

          if submission_languages_languages.blank?
            result_lang = [Goo.main_languages.first.to_s]
          else
            result_lang = [submission_languages_languages.first]
          end
        else
          result_lang = Array(user_languages)
        end

        if result_lang.length == 1
          result_lang.first
        elsif result_lang.empty?
          Goo.main_languages.first.to_s
        else
          result_lang
        end
      end

      def self.get_submission_languages(submission_natural_language = [])
        submission_natural_language = submission_natural_language.values.flatten if submission_natural_language.is_a?(Hash)
        submission_natural_language.map { |natural_language| natural_language.to_s.split('/').last[0..1].to_sym }.compact
      end

      def self.type(current_cls, hashed_obj)
        if current_cls.respond_to?(:type_uri)
          # For internal class
          proc = current_cls
        elsif hashed_obj.respond_to?(:type_uri)
          # For External and Interportal class
          proc = hashed_obj
        end

        collection = hashed_obj.respond_to?(:collection) ? hashed_obj.collection : nil
        if collection
          proc.type_uri(collection).to_s
        else
          proc.type_uri.to_s
        end
      end

      def self.generate_context(object, serialized_attrs = [], options = {})
        return remove_unused_attrs(CONTEXTS[object.hash], serialized_attrs) unless CONTEXTS[object.hash].nil?
        hash = {}
        current_cls = object.respond_to?(:klass) ? object.klass : object.class
        class_attributes = current_cls.attributes
        hash["@vocab"] = Goo.vocabulary.to_s
        class_attributes.each do |attr|
          if current_cls.model_settings[:range].key?(attr)
            linked_model = current_cls.model_settings[:range][attr]
          end

          if linked_model && linked_model.ancestors.include?(Goo::Base::Resource) && !embedded?(object, attr)
            # linked object
            predicate = { "@id" => linked_model.type_uri.to_s, "@type" => "@id" }
          else
            # use the original predicate property if set
            predicate_attr = if current_cls.model_settings[:attributes][attr][:property].is_a?(Proc)
                               attr
                             else
                               current_cls.model_settings[:attributes][attr][:property] || attr
                             end

            # predicate with custom namespace
            # if the namespace can be resolved by the namespaces added in Goo then it will be resolved.
            predicate = "#{Goo.vocabulary(current_cls.model_settings[:attributes][attr][:namespace])&.to_s}#{predicate_attr}"
          end
          hash[attr] = predicate unless predicate.nil?
        end
        context = { "@context" => hash }
        CONTEXTS[object.hash] = context
        context = remove_unused_attrs(context, serialized_attrs) unless options[:params] && options[:params]["full_context"].eql?("true")
        context
      end

      def self.generate_links_context(object)
        current_cls = object.respond_to?(:klass) ? object.klass : object.class
        links = current_cls.hypermedia_settings[:link_to]
        links_context = {}
        links.each do |link|
          links_context[link.type] = link.type_uri.to_s
        end
        return { "@context" => links_context }
      end

      def self.remove_unused_attrs(context, serialized_attrs = [])
        new_context = context["@context"].reject { |k, v| !serialized_attrs.include?(k) && !k.to_s.start_with?("@") }
        { "@context" => new_context }
      end

      def self.embedded?(object, attribute)
        current_cls = object.respond_to?(:klass) ? object.klass : object.class
        embedded = false
        embedded = true if current_cls.hypermedia_settings[:embed].include?(attribute)
        embedded = true if (
          !current_cls.hypermedia_settings[:embed_values].empty? && current_cls.hypermedia_settings[:embed_values].first.key?(attribute)
        )
        embedded
      end

      def self.generate_context?(options)
        params = options[:params]
        params.nil? ||
          (params["no_context"].nil? ||
            !params["no_context"].eql?("true")) &&
            (params["display_context"].nil? ||
              !params["display_context"].eql?("false"))
      end

      def self.generate_links?(options)
        params = options[:params]
        params.nil? ||
          (params["no_links"].nil? ||
            !params["no_links"].eql?("true")) &&
            (params["display_links"].nil? ||
              !params["display_links"].eql?("false"))
      end
    end
  end
end