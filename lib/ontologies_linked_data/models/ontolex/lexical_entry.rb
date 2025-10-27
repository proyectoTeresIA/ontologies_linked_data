module LinkedData
  module Models
    module OntoLex
      class LexicalEntry < LinkedData::Models::Base
        model :lexical_entry, name_with: :id, collection: :submission,
                              namespace: :ontolex, schemaless: :true,
                              rdf_type: ->(*_x) { RDF::URI("http://www.w3.org/ns/lemon/ontolex#LexicalEntry") }

        attribute :lemma, namespace: :ontolex
        attribute :language, namespace: :dcterms
        attribute :partOfSpeech, namespace: :lexinfo
        attribute :termType, namespace: :lexinfo, property: :termType
        attribute :form, namespace: :ontolex, enforce: [:list], range: -> { LinkedData::Models::OntoLex::Form }
        attribute :canonicalForm, namespace: :ontolex, range: -> { LinkedData::Models::OntoLex::Form }
        attribute :otherForm, namespace: :ontolex, range: -> { LinkedData::Models::OntoLex::Form }
        attribute :sense, namespace: :ontolex, enforce: [:list], range: -> { LinkedData::Models::OntoLex::LexicalSense }
        attribute :evokes, namespace: :ontolex, property: :evokes, range: -> { LinkedData::Models::OntoLex::LexicalConcept }
        attribute :submission, collection: ->(s) { s.resource_id }, namespace: :metadata

    # Hypermedia / serialization
        do_not_load :form, :canonicalForm, :otherForm, :sense
    # Keep base serialization minimal but include relation fields for list/show parity
    serialize_default :lemma, :language, :partOfSpeech, :termType, :form, :sense, :evokes
        serialize_never :submission
        # Do not embed related resources to keep payloads light
    serialize_methods :properties, :computed
        links_load submission: [ontology: [:acronym]]
        link_to LinkedData::Hypermedia::Link.new("self", ->(s) { "ontologies/#{s.submission.ontology.acronym}/lexical_entries/#{CGI.escape(s.id.to_s)}" }, self.uri_type),
                LinkedData::Hypermedia::Link.new("ontology", ->(s) { "ontologies/#{s.submission.ontology.acronym}" }, Goo.vocabulary["Ontology"])

        def properties
          self.unmapped
        end

        # Provide relation methods that return IRIs (arrays); these are used by serialize_methods
        def form
          begin
            return Array(self.form_ids)
          rescue StandardError
            return []
          end
        end

        def sense
          begin
            return Array(self.sense_ids)
          rescue StandardError
            return []
          end
        end

        def evokes
          begin
            return Array(self.evokes_ids)
          rescue StandardError
            return []
          end
        end

        # Provide a computed payload to guarantee presence of core fields in serialization
        def computed
          out = {}
          l = self.lemma
          out[:lemma] = l unless l.nil? || (l.respond_to?(:empty?) && l.empty?)
          # derive language at the entry level
          langs = self.language
          out[:language] = langs unless langs.nil? || (langs.respond_to?(:empty?) && langs.empty?)
          pos = self.partOfSpeech
          out[:partOfSpeech] = pos unless pos.nil? || (pos.respond_to?(:empty?) && pos.empty?)
          tt = self.termType
          out[:termType] = tt unless tt.nil? || (tt.respond_to?(:empty?) && tt.empty?)
          # Surface relation IRIs here so to_flex_hash includes them in JSON
          f = self.form_ids
          out[:form] = f if f && !(f.respond_to?(:empty?) && f.empty?)
          s = self.sense_ids
          out[:sense] = s if s && !(s.respond_to?(:empty?) && s.empty?)
          e = self.evokes_ids
          out[:evokes] = e if e && !(e.respond_to?(:empty?) && e.empty?)
          out
        end

        # Assign computed values to attributes so serializer includes them for list/show
        def ensure_computed
          return if defined?(@_computed_populated) && @_computed_populated
          data = computed
          if data && data.is_a?(Hash)
            self.lemma = data[:lemma] if data.key?(:lemma)
            self.language = data[:language] if data.key?(:language)
            self.partOfSpeech = data[:partOfSpeech] if data.key?(:partOfSpeech)
            self.termType = data[:termType] if data.key?(:termType)
          end
          @_computed_populated = true
        end

        # Compute concepts directly evoked by the entry (no traversal via senses)
        def evokes
          val = instance_variable_defined?(:@evokes) ? instance_variable_get(:@evokes) : nil
          present = !(val.nil? || (val.respond_to?(:empty?) && val.empty?))
          return val if present
          return [] unless self.submission

          graph = self.submission.id
          s = self.id
          evokes_p = "http://www.w3.org/ns/lemon/ontolex#evokes"

          qry = [
            "SELECT DISTINCT ?c WHERE {",
            "  GRAPH <#{graph}> {",
            "    VALUES ?s { <#{s}> }",
            "    ?s <#{evokes_p}> ?c .",
            "    FILTER(isIRI(?c))",
            "  }",
            "}",
          ].join("\n")

          epr = Goo.sparql_query_client(:main)
          cs = []
          begin
            epr.query(qry, graphs: [graph]).each { |row| cs << row[:c].to_s }
          rescue StandardError
          end
          cs.uniq!
          # Map to read_only concepts for potential downstream indexing
          resources = cs.map do |iri|
            begin
              LinkedData::Models::OntoLex::LexicalConcept.read_only_enriched(id: RDF::URI(iri), submission: self.submission)
            rescue StandardError
              iri
            end
          end
          instance_variable_set(:@evokes, resources)
          resources
        end

        # Compute language for entry strictly from explicit language triples on the entry
        def language
          val = instance_variable_defined?(:@language) ? instance_variable_get(:@language) : nil
          present = !(val.nil? || (val.respond_to?(:empty?) && val.empty?))
          return val if present
          langs = []
          if self.submission
            graph = self.submission.id
            s = self.id
            lang_p = "http://purl.org/dc/terms/language"
            lang_dc = "http://purl.org/dc/elements/1.1/language"
            q = [
              "SELECT DISTINCT ?l WHERE {",
              "  GRAPH <#{graph}> {",
              "    VALUES ?s { <#{s}> }",
              "    { ?s <#{lang_p}> ?l } UNION { ?s <#{lang_dc}> ?l } .",
              "  }",
              "}",
            ].join("\n")
            begin
              Goo.sparql_query_client(:main).query(q, graphs: [graph]).each { |row| langs << row[:l].to_s }
            rescue StandardError
            end
          end
          langs.uniq!
          langs
        end

        # Compute forms via SPARQL; include ontolex and legacy lemon predicates, and type-based discovery
        def form
          return @computed_forms if defined?(@computed_forms)
          return [] unless self.submission

          graph = self.submission.id
          s = self.id
          form_p = "http://www.w3.org/ns/lemon/ontolex#form"
          lex_form_p = "http://www.w3.org/ns/lemon/ontolex#lexicalForm"
          can_p = "http://www.w3.org/ns/lemon/ontolex#canonicalForm"
          oth_p = "http://www.w3.org/ns/lemon/ontolex#otherForm"
          l_form_p = "http://lemon-model.net/lemon#form"
          l_can_p = "http://lemon-model.net/lemon#canonicalForm"
          l_oth_p = "http://lemon-model.net/lemon#otherForm"
          wr_p = "http://www.w3.org/ns/lemon/ontolex#writtenRep"
          wr_p_lemon = "http://lemon-model.net/lemon#writtenRep"
          lang_p = "http://purl.org/dc/terms/language"
          ft_p = "http://www.w3.org/ns/lemon/ontolex#formType"

          qry = [
            "SELECT ?f ?w ?l ?ft WHERE {",
            "  GRAPH <#{graph}> {",
            "    VALUES ?s { <#{s}> }",
            "    { ?s <#{form_p}> ?f } UNION { ?s <#{lex_form_p}> ?f } UNION { ?s <#{can_p}> ?f } UNION { ?s <#{oth_p}> ?f } UNION { ?s <#{l_form_p}> ?f } UNION { ?s <#{l_can_p}> ?f } UNION { ?s <#{l_oth_p}> ?f } UNION { ?s ?any ?f . { ?f a <http://www.w3.org/ns/lemon/ontolex#Form> } UNION { ?f a <http://lemon-model.net/lemon#Form> } } .",
            "    OPTIONAL { { ?f <#{wr_p}> ?w } UNION { ?f <#{wr_p_lemon}> ?w } }",
            "    OPTIONAL { ?f <#{lang_p}> ?l }",
            "    OPTIONAL { ?f <#{ft_p}> ?ft }",
            "    FILTER(isIRI(?f))",
            "  }",
            "}",
          ].join("\n")

          epr = Goo.sparql_query_client(:main)
          buckets = {}
          begin
            epr.query(qry, graphs: [graph]).each do |row|
              fid = RDF::URI(row[:f].to_s)
              key = fid.to_s
              buckets[key] ||= { id: fid, submission: self.submission, writtenRep: [], language: [], formType: [] }
              buckets[key][:writtenRep] << row[:w].to_s if row[:w]
              buckets[key][:language] << row[:l].to_s if row[:l]
              buckets[key][:formType] << row[:ft].to_s if row[:ft]
            end
          rescue StandardError
          end
          # Deduplicate scalar arrays
          buckets.values.each do |attrs|
            [:writtenRep, :language, :formType].each do |k|
              arr = attrs[k]
              attrs[k] = arr.uniq if arr.respond_to?(:uniq!)
            end
          end
          @computed_forms = buckets.values.map { |attrs| LinkedData::Models::OntoLex::Form.read_only(attrs) }
          @computed_forms
        end

        # Lightweight IRIs for related forms
        def form_ids
          return [] unless self.submission
          graph = self.submission.id
          s = self.id
          form_p = "http://www.w3.org/ns/lemon/ontolex#form"
          lex_form_p = "http://www.w3.org/ns/lemon/ontolex#lexicalForm"
          can_p = "http://www.w3.org/ns/lemon/ontolex#canonicalForm"
          oth_p = "http://www.w3.org/ns/lemon/ontolex#otherForm"
          l_form_p = "http://lemon-model.net/lemon#form"
          l_can_p = "http://lemon-model.net/lemon#canonicalForm"
          l_oth_p = "http://lemon-model.net/lemon#otherForm"
          q = [
            "SELECT DISTINCT ?f WHERE {",
            "  GRAPH <#{graph}> {",
            "    VALUES ?s { <#{s}> }",
            "    { ?s <#{form_p}> ?f } UNION { ?s <#{lex_form_p}> ?f } UNION { ?s <#{can_p}> ?f } UNION { ?s <#{oth_p}> ?f } UNION { ?s <#{l_form_p}> ?f } UNION { ?s <#{l_can_p}> ?f } UNION { ?s <#{l_oth_p}> ?f } UNION { ?s ?any ?f . { ?f a <http://www.w3.org/ns/lemon/ontolex#Form> } UNION { ?f a <http://lemon-model.net/lemon#Form> } } .",
            "    FILTER(isIRI(?f))",
            "  }",
            "}",
          ].join("\n")
          ids = []
          begin
            Goo.sparql_query_client(:main).query(q, graphs: [graph]).each { |row| ids << row[:f].to_s }
          rescue StandardError
          end
          ids.uniq
        end

        # Compute senses via SPARQL; include direct, inverse, and concept path
        def sense
          return @computed_senses if defined?(@computed_senses)
          return [] unless self.submission

          graph = self.submission.id
          s = self.id
          sense_p = "http://www.w3.org/ns/lemon/ontolex#sense"
          isSenseOf_p = "http://www.w3.org/ns/lemon/ontolex#isSenseOf"
          # legacy lemon equivalents
          l_sense_p = "http://lemon-model.net/lemon#sense"
          l_isSenseOf_p = "http://lemon-model.net/lemon#isSenseOf"
          evokes_p = "http://www.w3.org/ns/lemon/ontolex#evokes"
          lex_sense_p = "http://www.w3.org/ns/lemon/ontolex#lexicalizedSense"
          def_p = "http://purl.org/dc/terms/definition"
          ex_p = "http://purl.org/dc/terms/example"
          ref_p = "http://www.w3.org/ns/lemon/ontolex#reference"
          lc_p = "http://www.w3.org/ns/lemon/ontolex#isLexicalizedSenseOf"

          qry = [
            "SELECT ?se ?d ?e ?r ?lc WHERE {",
            "  GRAPH <#{graph}> {",
            "    VALUES ?s { <#{s}> }",
            "    { ?s <#{sense_p}> ?se } UNION { ?se <#{isSenseOf_p}> ?s } UNION",
            "    { ?s <#{l_sense_p}> ?se } UNION { ?se <#{l_isSenseOf_p}> ?s } UNION",
            "    { <#{s}> <#{evokes_p}> ?c . ?c <#{lex_sense_p}> ?se } .",
            "    OPTIONAL { ?se <#{def_p}> ?d }",
            "    OPTIONAL { ?se <#{ex_p}> ?e }",
            "    OPTIONAL { ?se <#{ref_p}> ?r }",
            "    OPTIONAL { ?se <#{lc_p}> ?lc }",
            "    FILTER(isIRI(?se))",
            "  }",
            "}",
          ].join("\n")

          epr = Goo.sparql_query_client(:main)
          buckets = {}
          begin
            epr.query(qry, graphs: [graph]).each do |row|
              sid = RDF::URI(row[:se].to_s)
              key = sid.to_s
              buckets[key] ||= { id: sid, submission: self.submission, definition: [], example: [], reference: [], lexicalConcept: [] }
              buckets[key][:definition] << row[:d].to_s if row[:d]
              buckets[key][:example] << row[:e].to_s if row[:e]
              buckets[key][:reference] << row[:r].to_s if row[:r]
              buckets[key][:lexicalConcept] << row[:lc].to_s if row[:lc]
            end
          rescue StandardError
          end
          @computed_senses = buckets.values.map do |attrs|
            LinkedData::Models::OntoLex::LexicalSense.read_only(attrs)
          end
          @computed_senses
        end

        # Lightweight IRIs for related senses
        def sense_ids
          return [] unless self.submission
          graph = self.submission.id
          s = self.id
          sense_p = "http://www.w3.org/ns/lemon/ontolex#sense"
          isSenseOf_p = "http://www.w3.org/ns/lemon/ontolex#isSenseOf"
          l_sense_p = "http://lemon-model.net/lemon#sense"
          l_isSenseOf_p = "http://lemon-model.net/lemon#isSenseOf"
          evokes_p = "http://www.w3.org/ns/lemon/ontolex#evokes"
          lex_sense_p = "http://www.w3.org/ns/lemon/ontolex#lexicalizedSense"
          q = [
            "SELECT DISTINCT ?se WHERE {",
            "  GRAPH <#{graph}> {",
            "    VALUES ?s { <#{s}> }",
            "    { ?s <#{sense_p}> ?se } UNION { ?se <#{isSenseOf_p}> ?s } UNION",
            "    { ?s <#{l_sense_p}> ?se } UNION { ?se <#{l_isSenseOf_p}> ?s } UNION",
            "    { <#{s}> <#{evokes_p}> ?c . ?c <#{lex_sense_p}> ?se } .",
            "    FILTER(isIRI(?se))",
            "  }",
            "}",
          ].join("\n")
          ids = []
          begin
            Goo.sparql_query_client(:main).query(q, graphs: [graph]).each { |row| ids << row[:se].to_s }
          rescue StandardError
          end
          ids.uniq
        end

        # If lemma is not asserted on the entry, derive it from canonical/other forms' writtenRep
        def lemma
          val = instance_variable_defined?(:@lemma) ? instance_variable_get(:@lemma) : nil
          present = !(val.nil? || (val.respond_to?(:empty?) && val.empty?))
          return val if present
          reps = []
          Array(self.form).each do |f|
            if f.respond_to?(:writtenRep) && f.writtenRep
              reps.concat(Array(f.writtenRep))
            end
          end
          reps.uniq!
          reps
        end

        # If partOfSpeech is not asserted on the entry, derive it from the entry or any related form
        def partOfSpeech
          val = instance_variable_defined?(:@partOfSpeech) ? instance_variable_get(:@partOfSpeech) : nil
          present = !(val.nil? || (val.respond_to?(:empty?) && val.empty?))
          return val if present
          return [] unless self.submission
          graph = self.submission.id
          s = self.id
          pos_http = "http://www.lexinfo.net/ontology/3.0/lexinfo#partOfSpeech"
          pos_https = "https://www.lexinfo.net/ontology/3.0/lexinfo#partOfSpeech"
          pos_20 = "http://lexinfo.net/ontology/2.0/lexinfo#partOfSpeech"
          # legacy lemon POS (older data sometimes uses lemon:partOfSpeech)
          l_pos = "http://lemon-model.net/lemon#partOfSpeech"
          form_p = "http://www.w3.org/ns/lemon/ontolex#form"
          can_p = "http://www.w3.org/ns/lemon/ontolex#canonicalForm"
          oth_p = "http://www.w3.org/ns/lemon/ontolex#otherForm"
          qry = [
            "SELECT DISTINCT ?pos WHERE {",
            "  GRAPH <#{graph}> {",
            "    VALUES ?s { <#{s}> }",
            "    { ?s <#{pos_http}> ?pos } UNION { ?s <#{pos_https}> ?pos } UNION { ?s <#{pos_20}> ?pos } UNION { ?s <#{l_pos}> ?pos } UNION ",
            "    { ?s (<#{form_p}>|<#{can_p}>|<#{oth_p}>) ?f . { ?f <#{pos_http}> ?pos } UNION { ?f <#{pos_https}> ?pos } UNION { ?f <#{pos_20}> ?pos } UNION { ?f <#{l_pos}> ?pos } }",
            "  }",
            "}",
          ].join("\n")
          epr = Goo.sparql_query_client(:main)
          vals = []
          begin
            epr.query(qry, graphs: [graph]).each { |row| vals << row[:pos].to_s }
          rescue StandardError
          end
          vals.uniq
        end

        # Derive termType if missing (check entry or any related form for robustness)
        def termType
          val = instance_variable_defined?(:@termType) ? instance_variable_get(:@termType) : nil
          present = !(val.nil? || (val.respond_to?(:empty?) && val.empty?))
          return val if present
          return [] unless self.submission
          graph = self.submission.id
          s = self.id
          tt_http = "http://www.lexinfo.net/ontology/3.0/lexinfo#termType"
          tt_https = "https://www.lexinfo.net/ontology/3.0/lexinfo#termType"
          tt_20 = "http://lexinfo.net/ontology/2.0/lexinfo#termType"
          form_p = "http://www.w3.org/ns/lemon/ontolex#form"
          can_p = "http://www.w3.org/ns/lemon/ontolex#canonicalForm"
          oth_p = "http://www.w3.org/ns/lemon/ontolex#otherForm"
          qry = [
            "SELECT DISTINCT ?et WHERE {",
            "  GRAPH <#{graph}> {",
            "    VALUES ?s { <#{s}> }",
            "    { ?s <#{tt_http}> ?et } UNION { ?s <#{tt_https}> ?et } UNION { ?s <#{tt_20}> ?et } UNION { ?s (<#{form_p}>|<#{can_p}>|<#{oth_p}>) ?f . { ?f <#{tt_http}> ?et } UNION { ?f <#{tt_https}> ?et } UNION { ?f <#{tt_20}> ?et } }",
            "  }",
            "}",
          ].join("\n")
          epr = Goo.sparql_query_client(:main)
          vals = []
          begin
            epr.query(qry, graphs: [graph]).each { |row| vals << row[:et].to_s }
          rescue StandardError
          end
          vals.uniq
        end

        # Build a stable per-submission Solr id similar to Class/Property
        def index_id
          self.bring(:submission) if self.bring?(:submission)
          return nil unless self.submission
          self.submission.bring(:submissionId) if self.submission.bring?(:submissionId)
          self.submission.bring(:ontology) if self.submission.bring?(:ontology)
          return nil unless self.submission.ontology
          self.submission.ontology.bring(:acronym) if self.submission.ontology.bring?(:acronym)
          "#{self.id.to_s}_#{self.submission.ontology.acronym}_#{self.submission.submissionId}"
        end

        # Compute Solr document for lexical entries
        def index_doc(to_set = nil)
          doc = {}
          # Required fields: stable unique id for this submission and original resource IRI
          # Use a stable per-submission unique id for the Solr document, similar to classes/properties
          doc[:id] = self.index_id || self.id.to_s
          doc[:resource_id] = self.id.to_s
          self.bring(:submission) if self.bring?(:submission)
          return doc unless self.submission

          # Submission/ontology fields
          doc[:ontologyId] = self.submission.id.to_s
          doc[:submissionAcronym] = self.submission.ontology.acronym
          doc[:submissionId] = self.submission.submissionId

          # Core lexical fields (lemma/writtenRep/language/pos/type)
          all_attrs = self.to_hash(include_languages: true)

          [:lemma, :language, :partOfSpeech, :termType].each do |att|
            val = all_attrs[att]
            next if val.nil? || (val.respond_to?(:empty?) && val.empty?)
            if val.is_a?(Hash)
              # language-tagged hash → index all variants and per-language dynamic
              doc[att] = val.values.flatten
              val.each { |lang, values| doc["#{att}_#{lang}".to_sym] = values }
            else
              doc[att] = Array(val).map(&:to_s)
            end
          end

          # Forms: flatten writtenRep from embedded forms if present
          if self.form
            reps = []
            Array(self.form).each do |f|
              if f.respond_to?(:writtenRep) && f.writtenRep
                reps.concat(Array(f.writtenRep))
              end
            end
            reps.uniq!
            doc[:writtenRep] = reps unless reps.empty?
          end

          # Senses: definitions/examples and concept labels
          if self.sense
            defs = []
            exs = []
            concepts = []
            concept_labels = []
            Array(self.sense).each do |s|
              defs.concat(Array(s.definition)) if s.respond_to?(:definition) && s.definition
              exs.concat(Array(s.example)) if s.respond_to?(:example) && s.example
              if s.respond_to?(:lexicalConcept) && s.lexicalConcept
                Array(s.lexicalConcept).each do |lc|
                  concepts << lc.id.to_s
                  if lc.respond_to?(:prefLabel) && lc.prefLabel
                    concept_labels.concat(Array(lc.prefLabel))
                  end
                end
              end
            end
            doc[:definition] = defs unless defs.empty?
            doc[:example] = exs unless exs.empty?
            doc[:concept] = concepts.uniq unless concepts.empty?
            doc[:conceptLabel] = concept_labels.uniq unless concept_labels.empty?
          end

          # Concepts directly evoked by the entry (ensure they are indexed even without senses)
          begin
            evoked_ids = self.respond_to?(:evokes_ids) ? Array(self.evokes_ids) : []
            unless evoked_ids.empty?
              doc[:concept] = (Array(doc[:concept]) + evoked_ids).uniq
            end
          rescue StandardError
          end

          # Raw properties if needed
          props = properties_for_indexing
          if props
            doc[:property] = props[:property]
            doc[:propertyRaw] = props[:propertyRaw]
          end

          doc
        end

        def properties_for_indexing
          self_props = self.properties
          return nil if self_props.nil?

          props = {}
          prop_vals = []
          self_props.each do |attr_key, attr_val|
            if attr_val.is_a?(Array)
              props[attr_key] = []
              attr_val.uniq.each do |val|
                real = val.kind_of?(Goo::Base::Resource) ? val.id.to_s : val.to_s.strip
                next if real.respond_to?(:empty?) && real.empty?
                prop_vals << real
                props[attr_key] << real
              end
            else
              real = attr_val.to_s.strip
              next if real.respond_to?(:empty?) && real.empty?
              prop_vals << real
              props[attr_key] = real
            end
          end

          begin
            { propertyRaw: MultiJson.dump(props), property: prop_vals.uniq }
          rescue JSON::GeneratorError
            nil
          end
        end

        # Route searches to the lexical backend (Solr core)
        def self.search(q, params = {})
          super(q, params, :lexical)
        end

        # Ensure computed fields (including embedded form/sense) present before serialization
        def to_hash(options = {})
          begin
            ensure_computed
          rescue StandardError
          end
          h = super(options)
          # Always return IRIs for relations as arrays (even when empty)
          begin
            h["form"] = Array(self.form_ids)
          rescue StandardError
            h["form"] = []
          end
          begin
            h["sense"] = Array(self.sense_ids)
          rescue StandardError
            h["sense"] = []
          end
          begin
            h["evokes"] = Array(self.evokes_ids)
          rescue StandardError
            h["evokes"] = []
          end
          h
        end

        # Lightweight helper to get evoked concept IRIs without materializing LexicalConcept objects
        def evokes_ids
          return [] unless self.submission && self.id
          graph = self.submission.id
          s = self.id
          evokes_p = "http://www.w3.org/ns/lemon/ontolex#evokes"
          q = [
            "SELECT DISTINCT ?c WHERE {",
            "  GRAPH <#{graph}> {",
            "    VALUES ?s { <#{s}> }",
            "    ?s <#{evokes_p}> ?c .",
            "    FILTER(isIRI(?c))",
            "  }",
            "}",
          ].join("\n")
          ids = []
          begin
            Goo.sparql_query_client(:main).query(q, graphs: [graph]).each { |row| ids << row[:c].to_s }
          rescue StandardError
          end
          ids.uniq
        end

        # Backwards compatibility helper
        def concept_ids
          evokes_ids
        end

        def self.read_only_enriched(id:, submission:, lightweight: false)
          return nil unless id && submission
          rid = id.is_a?(RDF::URI) ? id : RDF::URI(id.to_s)
          inst = self.new
          begin
            inst.id = rid
          rescue ArgumentError
            # Fallback: set instance var directly to avoid strict setter guardrails
            inst.instance_variable_set(:@id, rid)
          end
          begin
            inst.submission = submission
          rescue ArgumentError
            inst.instance_variable_set(:@submission, submission)
          end
          unless lightweight
            begin
              inst.ensure_computed
            rescue StandardError
            end
          end
          attrs = { id: inst.id, submission: submission }
          begin
            l = inst.respond_to?(:lemma) ? inst.lemma : nil
            attrs[:lemma] = l if l && !(l.respond_to?(:empty?) && l.empty?)
          rescue StandardError
          end
          begin
            langs = inst.respond_to?(:language) ? inst.language : nil
            attrs[:language] = langs if langs && !(langs.respond_to?(:empty?) && langs.empty?)
          rescue StandardError
          end
          begin
            pos = inst.respond_to?(:partOfSpeech) ? inst.partOfSpeech : nil
            attrs[:partOfSpeech] = pos if pos && !(pos.respond_to?(:empty?) && pos.empty?)
          rescue StandardError
          end
          begin
            tt = inst.respond_to?(:termType) ? inst.termType : nil
            attrs[:termType] = tt if tt && !(tt.respond_to?(:empty?) && tt.empty?)
          rescue StandardError
          end
          # Add relation IRIs (never embed heavy objects here)
          begin
            attrs[:form] = Array(inst.form_ids) if inst.respond_to?(:form_ids)
          rescue StandardError
          end
          begin
            attrs[:sense] = Array(inst.sense_ids) if inst.respond_to?(:sense_ids)
          rescue StandardError
          end
          begin
            attrs[:evokes] = Array(inst.evokes_ids) if inst.respond_to?(:evokes_ids)
          rescue StandardError
          end
          self.read_only(attrs)
        end

        # Class-level helpers
        def self.count_in_submission(submission)
          return 0 unless submission
          graph = submission.id
          ontolex = "http://www.w3.org/ns/lemon/ontolex#"
          lemon = "http://lemon-model.net/lemon#"
          epr = Goo.sparql_query_client(:main)
          begin
            q = [
              "SELECT (COUNT(DISTINCT ?s) AS ?count) WHERE {",
              "  GRAPH <#{graph}> {",
              "    { ?s a <#{ontolex}LexicalEntry> } UNION { ?s a <#{lemon}LexicalEntry> } UNION",
              "    { ?s (<#{ontolex}form>|<#{ontolex}lexicalForm>|<#{ontolex}canonicalForm>|<#{ontolex}otherForm>|<#{lemon}form>|<#{lemon}canonicalForm>|<#{lemon}otherForm>) ?f FILTER(isIRI(?f)) } UNION",
              "    { ?s (<#{ontolex}sense>|<#{lemon}sense>) ?se FILTER(isIRI(?se)) } UNION",
              "    { ?se (<#{ontolex}isSenseOf>|<#{lemon}isSenseOf>) ?s } UNION",
              "    { ?s <#{ontolex}evokes> ?c }",
              "    FILTER(isIRI(?s))",
              "    FILTER NOT EXISTS { ?s a <#{ontolex}Form> }",
              "    FILTER NOT EXISTS { ?s a <#{lemon}Form> }",
              "    FILTER NOT EXISTS { ?s a <#{ontolex}LexicalSense> }",
              "  }",
              "}",
            ].join("\n")
            row = epr.query(q, graphs: [graph]).first
            (row && row[:count]) ? row[:count].to_s.to_i : 0
          rescue StandardError
            0
          end
        end

        def self.list_in_submission(submission, page, size, _include_attrs = [])
          return [] unless submission
          graph = submission.id
          ontolex = "http://www.w3.org/ns/lemon/ontolex#"
          lemon = "http://lemon-model.net/lemon#"
          offset = (page - 1) * size
          
          # Simplified query - only select LexicalEntry types
          q = [
            "SELECT DISTINCT ?s WHERE {",
            "  GRAPH <#{graph}> {",
            "    { ?s a <#{ontolex}LexicalEntry> } UNION { ?s a <#{lemon}LexicalEntry> }",
            "    FILTER(isIRI(?s))",
            "  }",
            "} ORDER BY ?s LIMIT #{size} OFFSET #{offset}",
          ].join("\n")
          
          epr = Goo.sparql_query_client(:main)
          rows = []
          begin
            rows = epr.query(q, graphs: [graph])
          rescue StandardError
            rows = []
          end
          ids = rows.map { |row| row[:s].to_s }
          return [] if ids.empty?
          
          # Batch query for entry properties
          build_entries_batch(submission, ids, epr, graph)
        end

        # Helper to batch-build entries
        def self.build_entries_batch(submission, ids, epr, graph)
          lang_p = "http://purl.org/dc/terms/language"
          lang_dc = "http://purl.org/dc/elements/1.1/language"
          pos_http = "http://www.lexinfo.net/ontology/3.0/lexinfo#partOfSpeech"
          pos_https = "https://www.lexinfo.net/ontology/3.0/lexinfo#partOfSpeech"
          pos_20 = "http://lexinfo.net/ontology/2.0/lexinfo#partOfSpeech"
          l_pos = "http://lemon-model.net/lemon#partOfSpeech"
          tt_http = "http://www.lexinfo.net/ontology/3.0/lexinfo#termType"
          tt_https = "https://www.lexinfo.net/ontology/3.0/lexinfo#termType"
          tt_20 = "http://lexinfo.net/ontology/2.0/lexinfo#termType"
          wr_p = "http://www.w3.org/ns/lemon/ontolex#writtenRep"
          wr_p_lemon = "http://lemon-model.net/lemon#writtenRep"
          form_p = "http://www.w3.org/ns/lemon/ontolex#form"
          can_p = "http://www.w3.org/ns/lemon/ontolex#canonicalForm"
          oth_p = "http://www.w3.org/ns/lemon/ontolex#otherForm"
          sense_p = "http://www.w3.org/ns/lemon/ontolex#sense"
          evokes_p = "http://www.w3.org/ns/lemon/ontolex#evokes"
          
          values = ids.map { |id| "<#{id}>" }.join(" ")
          
          # Batch query for language, POS, termType, and relations
          batch_q = [
            "SELECT ?e ?p ?o WHERE {",
            "  GRAPH <#{graph}> {",
            "    VALUES ?e { #{values} }",
            "    ?e ?p ?o .",
            "    FILTER(?p IN (<#{lang_p}>, <#{lang_dc}>, <#{pos_http}>, <#{pos_https}>, <#{pos_20}>, <#{l_pos}>, <#{tt_http}>, <#{tt_https}>, <#{tt_20}>, <#{form_p}>, <#{can_p}>, <#{oth_p}>, <#{sense_p}>, <#{evokes_p}>))",
            "  }",
            "}",
          ].join("\n")
          
          # Batch query for lemma (writtenRep from forms)
          lemma_q = [
            "SELECT ?e ?w WHERE {",
            "  GRAPH <#{graph}> {",
            "    VALUES ?e { #{values} }",
            "    ?e (<#{form_p}>|<#{can_p}>|<#{oth_p}>) ?f .",
            "    { ?f <#{wr_p}> ?w } UNION { ?f <#{wr_p_lemon}> ?w }",
            "  }",
            "}",
          ].join("\n")
          
          # Collect results by entry ID
          entry_attrs = {}
          ids.each { |id| entry_attrs[id] = { id: RDF::URI(id), submission: submission } }
          
          begin
            epr.query(batch_q, graphs: [graph]).each do |row|
              eid = row[:e].to_s
              next unless entry_attrs[eid]
              
              case row[:p].to_s
              when lang_p, lang_dc
                (entry_attrs[eid][:language] ||= []) << row[:o].to_s
              when pos_http, pos_https, pos_20, l_pos
                (entry_attrs[eid][:partOfSpeech] ||= []) << row[:o].to_s
              when tt_http, tt_https, tt_20
                (entry_attrs[eid][:termType] ||= []) << row[:o].to_s
              when form_p, can_p, oth_p
                (entry_attrs[eid][:form] ||= []) << row[:o].to_s
              when sense_p
                (entry_attrs[eid][:sense] ||= []) << row[:o].to_s
              when evokes_p
                (entry_attrs[eid][:evokes] ||= []) << row[:o].to_s
              end
            end
          rescue StandardError
          end
          
          # Get lemma from forms
          begin
            epr.query(lemma_q, graphs: [graph]).each do |row|
              eid = row[:e].to_s
              next unless entry_attrs[eid]
              (entry_attrs[eid][:lemma] ||= []) << row[:w].to_s
            end
          rescue StandardError
          end
          
          # Dedup and create read_only objects
          entry_attrs.values.map do |attrs|
            [:language, :partOfSpeech, :termType, :form, :sense, :evokes, :lemma].each do |k|
              arr = attrs[k]
              attrs[k] = arr.uniq if arr.respond_to?(:uniq)
            end
            LinkedData::Models::OntoLex::LexicalEntry.read_only(attrs)
          end
        end

        # Build enriched read_only entries for specific IRIs (parity with list endpoint)
        def self.list_for_ids(submission, ids, _include_attrs = [])
          return [] unless submission && ids && !ids.empty?
          graph = submission.id
          epr = Goo.sparql_query_client(:main)
          entry_ids = ids.map(&:to_s).select { |s| !s.empty? }
          build_entries_batch(submission, entry_ids, epr, graph)
        end
      end
    end
  end
end
