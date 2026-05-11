module LinkedData
  module Services
    class SubmissionDiffGenerator < OntologySubmissionProcess

      def process(logger, options = nil)
        process_diff(logger)
      end

      def diff(logger, older)
        generate_diff(logger, init_diff_tool(older))
      end

      private

      # accepts another submission in 'older' (it should be an 'older' ontology version)
      def init_diff_tool(older)
        @submission.bring(:uploadFilePath)
        older.bring(:uploadFilePath)

        LinkedData::Diff::BubastisDiffCommand.new(
          File.expand_path(older.uploadFilePath.to_s),
          File.expand_path(@submission.uploadFilePath.to_s),
          File.expand_path(@submission.data_folder.to_s))
      end

      def bubastis_supported?
        @submission.bring(:hasOntologyLanguage) if @submission.bring?(:hasOntologyLanguage)
        lang = @submission.hasOntologyLanguage
        return true unless lang
        lang.bring(:acronym) if lang.respond_to?(:bring) && lang.bring?(:acronym)
        acronym = lang.respond_to?(:acronym) ? lang.acronym.to_s.upcase : lang.to_s.upcase
        acronym == 'OWL'
      rescue StandardError
        true
      end

      def process_diff(logger)
        if !bubastis_supported?
          logger.info("Diff process: skipping diff for unsupported ontology #{@submission.id}.")
          return
        end

        status = LinkedData::Models::SubmissionStatus.find('DIFF').first
        # Get previous submission from ontology.submissions
        @submission.ontology.bring(:submissions)
        submissions = @submission.ontology.submissions

        if submissions.nil?
          logger.info("Diff process: no submissions available for #{@submission.id}.")
        else
          submissions.each { |s| s.bring(:submissionId, :diffFilePath) }
          # Sort submissions in descending order of submissionId, extract last two submissions
          recent_submissions = submissions.sort { |a, b| b.submissionId <=> a.submissionId }[0..1]

          if recent_submissions.length > 1
            # validate that the most recent submission is the current submission
            if @submission.submissionId == recent_submissions.first.submissionId
              prev = recent_submissions.last

              # Ensure that prev is older than the current submission
              if @submission.submissionId > prev.submissionId
                # generate a diff
                begin
                  diff(logger,prev)
                  @submission.add_submission_status(status)
                rescue Exception => e
                  logger.error("#{e.class}: #{e.message}\n#{e.backtrace.join("\n\t")}")
                  logger.flush
                  @submission.add_submission_status(status.get_error_status)
                ensure
                  @submission.save
                end
              end
            end
          else
            logger.info("Diff process: no older submissions available for #{@submission.id}.")
          end
        end
      end

     
      def generate_diff(logger, diff_tool)
        begin
          @submission.bring_remaining
          @submission.bring(:diffFilePath)

          LinkedData::Diff.logger = logger
          @submission.diffFilePath = diff_tool.diff
          @submission.save
          logger.info("Diff generated successfully for #{@submission.id}")
          logger.flush
        rescue StandardError => e
          logger.error("Diff process for #{@submission.id} failed - #{e.class}: #{e.message}")
          logger.flush
          raise e
        end
      end

    end
  end
end