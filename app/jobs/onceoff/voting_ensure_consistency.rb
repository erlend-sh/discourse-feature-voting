# frozen_string_literal: true

module Jobs
  class VotingEnsureConsistency < ::Jobs::Onceoff
    def execute_onceoff(args)
      # archive votes to closed or archived or deleted topics
      DB.exec(<<~SQL)
        UPDATE discourse_voting_votes
        SET archive=true
        FROM topics
        WHERE topics.id = discourse_voting_votes.topic_id
        AND discourse_voting_votes.archive IS NOT TRUE
        AND (topics.closed OR topics.archived OR topics.deleted_at IS NOT NULL)
      SQL

      # un-archive votes to open topics
      DB.exec(<<~SQL)
        UPDATE discourse_voting_votes
        SET archive=false
        FROM topics
        WHERE topics.id = discourse_voting_votes.topic_id
        AND discourse_voting_votes.archive IS TRUE
        AND NOT topics.closed
        AND NOT topics.archived
        AND topics.deleted_at IS NULL
      SQL

      # delete duplicate votes
      DB.exec(<<~SQL)
        DELETE FROM discourse_voting_votes dvv1
        USING discourse_voting_votes dvv2
        WHERE dvv1.id < dvv2.id AND
              dvv1.user_id = dvv2.user_id AND
              dvv1.topic_id = dvv2.topic_id AND
              dvv1.archive = dvv2.archive
      SQL

      # delete votes associated with no topics
      DB.exec(<<~SQL)
        DELETE FROM discourse_voting_votes
        WHERE discourse_voting_votes.topic_id IS NULL
      SQL

      # delete duplicate vote counts for topics
      DB.exec(<<~SQL)
        DELETE FROM discourse_voting_vote_counters dvvc
        USING discourse_voting_vote_counters dvvc2
        WHERE dvvc.id < dvvc2.id AND
              dvvc.topic_id = dvvc2.topic_id AND
              dvvc.counter = dvvc2.counter
      SQL

      # insert missing vote counts for topics
      # ensures we have "something" for every topic with votes
      DB.exec(<<~SQL)
        WITH missing_ids AS (
          SELECT DISTINCT t.id FROM topics t
          JOIN discourse_voting_votes dvv ON t.id = dvv.topic_id
          LEFT JOIN discourse_voting_vote_counters dvvc ON t.id = dvvc.topic_id
          WHERE dvvc.topic_id IS NULL
        )
        INSERT INTO discourse_voting_vote_counters (counter, topic_id, created_at, updated_at)
        SELECT '0', id, now(), now() FROM missing_ids
      SQL

      # remove all superflous vote count custom fields
      DB.exec(<<~SQL)
        DELETE FROM discourse_voting_vote_counters
        WHERE topic_id IN (
          SELECT t1.id FROM topics t1
          LEFT JOIN discourse_voting_votes dvv
            ON dvv.topic_id = t1.id
          WHERE dvv.id IS NULL
        )
      SQL

      # correct topics vote counts
      DB.exec(<<~SQL)
        UPDATE discourse_voting_vote_counters dvvc
        SET counter = (
          SELECT COUNT(*) FROM discourse_voting_votes dvv
          WHERE dvvc.topic_id = dvv.topic_id
          GROUP BY dvv.topic_id
        )
      SQL
    end
  end
end
