module LinkedData
  module Services
    class SubmissionMetricsCalculator < OntologySubmissionProcess
      ISO639_3_TO_1 = {
        'spa' => 'es',
        'eng' => 'en',
        'cat' => 'ca',
        'glg' => 'gl',
        'eus' => 'eu'
      }.freeze

      def process(logger, options = nil)
        process_metrics(logger)
      end

      def generate_umls_metrics_file(tr_file_path = nil)
        tr_file_path ||= @submission.triples_file_path
        class_count = 0
        indiv_count = 0
        prop_count = 0
        max_depth = 0

        File.foreach(tr_file_path) do |line|
          class_count += 1 if line =~ /owl:Class/
          indiv_count += 1 if line =~ /owl:NamedIndividual/
          prop_count += 1 if line =~ /owl:ObjectProperty/
          prop_count += 1 if line =~ /owl:DatatypeProperty/
        end

        # Get max depth from the metrics.csv file which is already generated
        # by owlapi_wrapper when new submission of UMLS ontology is created.
        # Ruby code/sparql for calculating max_depth fails for large UMLS
        # ontologies with AllegroGraph backend
        metrics_from_owlapi = @submission.metrics_from_file
        max_depth = metrics_from_owlapi[1][3] unless metrics_from_owlapi.empty?

        generate_metrics_file(class_count, indiv_count, prop_count, max_depth, 0, 0, 0, 0, 0, 0)
      end

      private

      def process_metrics(logger)
        status = LinkedData::Models::SubmissionStatus.find('METRICS').first
        begin
          compute_metrics(logger)
          @submission.add_submission_status(status)
        rescue StandardError => e
          logger.error("#{e.class}: #{e.message}\n#{e.backtrace.join("\n\t")}")
          logger.flush
          @submission.metrics = nil
          @submission.add_submission_status(status.get_error_status)
        ensure
          @submission.save
        end
      end

      def compute_metrics(logger)
        metrics = metrics_for_submission(logger)
        metrics.id = RDF::URI.new(@submission.id.to_s + '/metrics')
        exist_metrics = LinkedData::Models::Metric.find(metrics.id).first
        exist_metrics.delete if exist_metrics
        metrics.save
        @submission.metrics = metrics
        @submission
      end

      def metrics_for_submission(logger)
        logger.info('metrics_for_submission start')
        logger.flush
        begin
          @submission.bring(:submissionStatus) if @submission.bring?(:submissionStatus)
          cls_metrics = LinkedData::Metrics.class_metrics(@submission, logger)
          logger.info('class_metrics finished')
          logger.flush
          metrics = LinkedData::Models::Metric.new

          cls_metrics.each do |k, v|
            unless v.instance_of?(Integer)
              begin
                v = Integer(v)
              rescue ArgumentError
                v = 0
              rescue TypeError
                v = 0
              end
            end
            metrics.send("#{k}=", v)
          end
          indiv_count = LinkedData::Metrics.number_individuals(logger, @submission)
          metrics.individuals = indiv_count
          logger.info('individuals finished')
          logger.flush
          prop_count = LinkedData::Metrics.number_properties(logger, @submission)
          metrics.properties = prop_count
          logger.info('properties finished')
          logger.flush

          # OntoLex counts
          ontolex_entries = 0
          ontolex_forms = 0
          ontolex_senses = 0
          ontolex_concepts = 0
          ontolex_translations = 0
          ontolex_languages = 0
          begin
            ontolex_entries = LinkedData::Models::OntoLex::LexicalEntry.count_in_submission(@submission)
            ontolex_forms   = LinkedData::Models::OntoLex::Form.count_in_submission(@submission)
            ontolex_senses  = LinkedData::Models::OntoLex::LexicalSense.count_in_submission(@submission)
            ontolex_concepts = LinkedData::Models::OntoLex::LexicalConcept.count_in_submission(@submission)
            ontolex_translations = count_ontolex_translations(@submission)
            ontolex_languages = count_ontolex_languages(@submission)
            metrics.ontolexEntries = ontolex_entries
            metrics.ontolexForms   = ontolex_forms
            metrics.ontolexSenses  = ontolex_senses
            metrics.ontolexConcepts = ontolex_concepts
            metrics.ontolexTranslations = ontolex_translations
            metrics.ontolexLanguages = ontolex_languages
            logger.info('ontolex metrics finished')
            logger.flush
          rescue StandardError => e
            logger.error("Error computing OntoLex metrics: #{e.message}")
            logger.flush
          end

          # re-generate metrics file
          generate_metrics_file(cls_metrics[:classes], indiv_count, prop_count, cls_metrics[:maxDepth],
                                ontolex_entries, ontolex_forms, ontolex_senses, ontolex_concepts,
                                ontolex_translations, ontolex_languages)
          logger.info('generation of metrics file finished')
          logger.flush
        rescue StandardError => e
          logger.error(e.message)
          logger.error(e)
          logger.flush
          metrics = nil
        end
        metrics
      end

      def generate_metrics_file(class_count, indiv_count, prop_count, max_depth,
                                ontolex_entries = 0, ontolex_forms = 0, ontolex_senses = 0, ontolex_concepts = 0,
                                ontolex_translations = 0, ontolex_languages = 0)
        CSV.open(@submission.metrics_path, 'wb') do |csv|
          csv << ['Class Count', 'Individual Count', 'Property Count', 'Max Depth',
                  'OntoLex Entries', 'OntoLex Forms', 'OntoLex Senses', 'OntoLex Concepts',
                  'OntoLex Translations', 'OntoLex Languages']
          csv << [class_count, indiv_count, prop_count, max_depth,
                  ontolex_entries, ontolex_forms, ontolex_senses, ontolex_concepts,
                  ontolex_translations, ontolex_languages]
        end
      end

      def count_ontolex_translations(submission)
        query = <<~SPARQL
          PREFIX vartrans: <http://www.w3.org/ns/lemon/vartrans#>
          SELECT (COUNT(DISTINCT ?target) AS ?count) WHERE {
            GRAPH <#{submission.id}> {
              ?sense vartrans:translation ?target .
            }
          }
        SPARQL
        run_count_query(query)
      end

      def count_ontolex_languages(submission)
        langs = Set.new

        # Prefer languages from writtenRep literals and explicit language attributes on forms.
        forms = LinkedData::Models::OntoLex::Form.in(submission).include(:writtenRep, :language).all
        forms.each do |form|
          extract_language_tokens(form.writtenRep, literal_map: true).each { |lang| langs << lang }
          extract_language_tokens(form.language).each { |lang| langs << lang }
        end

        # Fallback: if forms did not yield languages, inspect lexical entries.
        if langs.empty?
          entries = LinkedData::Models::OntoLex::LexicalEntry.in(submission).include(:language).all
          entries.each do |entry|
            extract_language_tokens(entry.language).each { |lang| langs << lang }
          end
        end

        langs.length
      rescue StandardError
        0
      end

      def extract_language_tokens(value, literal_map: false)
        return [] if value.nil?

        case value
        when Hash
          langs = []
          value.each do |k, v|
            # writtenRep is commonly a map lang=>literal(s); when literal_map=true
            # we only consume hash keys to avoid counting literal values as languages.
            langs << normalize_lang_token(k) unless k.to_s.empty?
            langs.concat(extract_language_tokens(v, literal_map: false)) unless literal_map
          end
          langs.compact.uniq
        when Array
          return [] if literal_map

          value.flat_map { |v| extract_language_tokens(v, literal_map: false) }.compact.uniq
        else
          return [] if literal_map

          if value.respond_to?(:language) && value.language
            [normalize_lang_token(value.language)].compact
          else
            [normalize_lang_token(value.to_s)].compact
          end
        end
      end

      def normalize_lang_token(raw)
        token = raw.to_s.strip.downcase
        return nil if token.empty?

        # Ignore non-language placeholders.
        return nil if %w[none all und].include?(token)

        # Support URI values like http://lexvo.org/id/iso639-3/spa
        token = token.split(/[\/#]/).last if token.include?('/') || token.include?('#')
        return nil if token.nil? || token.empty?

        # Keep only the primary language subtag for values like es-ES
        token = token.split('-').first
        return nil unless token.match?(/\A[a-z]{2,3}\z/)

        ISO639_3_TO_1.fetch(token, token)
      end

      def run_count_query(query)
        rs = Goo.sparql_query_client.query(query)
        rs.each do |sol|
          return sol[:count].object.to_i
        end
        0
      rescue StandardError
        0
      end
    end
  end
end
