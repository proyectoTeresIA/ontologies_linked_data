module LinkedData
  module Services
    class SubmissionMetricsCalculator < OntologySubmissionProcess
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

        metrics_from_owlapi = @submission.metrics_from_file
        max_depth = metrics_from_owlapi[1][3] unless metrics_from_owlapi.empty?

        generate_metrics_file(class_count, indiv_count, prop_count, max_depth)
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

      def ontolex_submission?
        @submission.bring(:hasOntologyLanguage) if @submission.bring?(:hasOntologyLanguage)
        lang = @submission.hasOntologyLanguage
        return false unless lang
        lang.bring(:acronym) if lang.respond_to?(:bring) && lang.bring?(:acronym)
        acronym = lang.respond_to?(:acronym) ? lang.acronym.to_s : lang.to_s
        acronym.upcase == 'ONTOLEX'
      rescue StandardError
        false
      end

      def metrics_for_submission(logger)
        logger.info('metrics_for_submission start')
        logger.flush
        begin
          @submission.bring(:submissionStatus) if @submission.bring?(:submissionStatus)
          metrics = LinkedData::Models::Metric.new

          if ontolex_submission?
            logger.info('OntoLex submission detected, computing OntoLex-specific metrics')
            compute_ontolex_metrics(metrics, logger)
          else
            compute_standard_metrics(metrics, logger)
          end

        rescue StandardError => e
          logger.error(e.message)
          logger.error(e)
          logger.flush
          metrics = nil
        end
        metrics
      end

      # ---------------------------------------------------------------------------
      # Standard OWL/SKOS metrics (unchanged behaviour)
      # ---------------------------------------------------------------------------
      def compute_standard_metrics(metrics, logger)
        cls_metrics = LinkedData::Metrics.class_metrics(@submission, logger)
        logger.info('class_metrics finished'); logger.flush

        cls_metrics.each do |k, v|
          unless v.instance_of?(Integer)
            begin; v = Integer(v)
            rescue ArgumentError, TypeError; v = 0
            end
          end
          metrics.send("#{k}=", v)
        end

        indiv_count = LinkedData::Metrics.number_individuals(logger, @submission)
        metrics.individuals = indiv_count
        logger.info('individuals finished'); logger.flush

        prop_count = LinkedData::Metrics.number_properties(logger, @submission)
        metrics.properties = prop_count
        logger.info('properties finished'); logger.flush

        generate_metrics_file(
          cls_metrics[:classes], indiv_count, prop_count, cls_metrics[:maxDepth]
        )
        logger.info('generation of metrics file finished'); logger.flush
        metrics
      end

      # ---------------------------------------------------------------------------
      # OntoLex-specific metrics
      # ---------------------------------------------------------------------------
      def compute_ontolex_metrics(metrics, logger)
        entries_count   = safe_count(logger, 'ontolexEntries')   { LinkedData::Models::OntoLex::LexicalEntry.count_in_submission(@submission) }
        forms_count     = safe_count(logger, 'ontolexForms')     { LinkedData::Models::OntoLex::Form.count_in_submission(@submission) }
        senses_count    = safe_count(logger, 'ontolexSenses')    { LinkedData::Models::OntoLex::LexicalSense.count_in_submission(@submission) }
        concepts_count  = safe_count(logger, 'ontolexConcepts')  { LinkedData::Models::OntoLex::LexicalConcept.count_in_submission(@submission) }
        translations    = safe_count(logger, 'ontolexTranslations') { count_translations }
        languages       = safe_count(logger, 'ontolexLanguages')    { count_distinct_languages }

        metrics.ontolexEntries      = entries_count
        metrics.ontolexForms        = forms_count
        metrics.ontolexSenses       = senses_count
        metrics.ontolexConcepts     = concepts_count
        metrics.ontolexTranslations = translations
        metrics.ontolexLanguages    = languages

        # Zero-out standard OWL fields so they don't pollute the display
        metrics.classes                    = 0
        metrics.individuals                = 0
        metrics.properties                 = 0
        metrics.maxDepth                   = 0
        metrics.maxChildCount              = 0
        metrics.averageChildCount          = 0
        metrics.classesWithOneChild        = 0
        metrics.classesWithMoreThan25Children = 0
        metrics.classesWithNoDefinition    = 0

        logger.info('OntoLex metrics finished'); logger.flush

        generate_metrics_file(
          0, 0, 0, 0,
          entries_count, forms_count, senses_count, concepts_count,
          translations, languages
        )
        metrics
      end

      # Count total translation links across all senses.
      # LexicalSense#translation is a list of related LexicalSense objects.
      def count_translations
        total = 0
        page  = 1
        size  = 500
        loop do
          batch = LinkedData::Models::OntoLex::LexicalSense
                    .in(@submission)
                    .include(:translation)
                    .page(page, size)
                    .all
          break if batch.empty?
          batch.each { |sense| total += Array(sense.translation).size }
          break if batch.size < size
          page += 1
        end
        total
      end

      # Count distinct language URIs across all LexicalEntries.
      # language is stored as a URI, e.g. http://lexvo.org/id/iso639-3/cat
      def count_distinct_languages
        languages = Set.new
        page = 1
        size = 500
        loop do
          batch = LinkedData::Models::OntoLex::LexicalEntry
                    .in(@submission)
                    .include(:language)
                    .page(page, size)
                    .all
          break if batch.empty?
          batch.each do |entry|
            Array(entry.language).each { |lang| languages.add(lang.to_s) unless lang.to_s.empty? }
          end
          break if batch.size < size
          page += 1
        end
        languages.size
      end

      def safe_count(logger, name)
        yield
      rescue StandardError => e
        logger.error("Error computing #{name}: #{e.message}")
        0
      end

      def generate_metrics_file(class_count, indiv_count, prop_count, max_depth,
                                ontolex_entries = 0, ontolex_forms = 0,
                                ontolex_senses = 0, ontolex_concepts = 0,
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
    end
  end
end