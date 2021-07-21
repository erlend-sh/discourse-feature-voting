# frozen_string_literal: true

# name: discourse-voting
# about: Adds the ability to vote on features in a specified category.
# version: 0.5
# author: Joe Buhlig joebuhlig.com, Sam Saffron
# url: https://github.com/discourse/discourse-voting

register_asset "stylesheets/common/feature-voting.scss"
register_asset "stylesheets/desktop/feature-voting.scss", :desktop
register_asset "stylesheets/mobile/feature-voting.scss", :mobile

enabled_site_setting :voting_enabled

Discourse.top_menu_items.push(:votes)
Discourse.anonymous_top_menu_items.push(:votes)
Discourse.filters.push(:votes)
Discourse.anonymous_filters.push(:votes)

after_initialize do
  module ::DiscourseVoting
    class Engine < ::Rails::Engine
      isolate_namespace DiscourseVoting
    end
  end

  load File.expand_path('../app/jobs/onceoff/voting_ensure_consistency.rb', __FILE__)
  load File.expand_path('../app/models/discourse_voting/category_setting.rb', __FILE__)
  load File.expand_path('../app/models/discourse_voting/topic_vote_count.rb', __FILE__)
  load File.expand_path('../app/models/discourse_voting/vote.rb', __FILE__)
  load File.expand_path('../lib/discourse_voting/categories_controller_extension.rb', __FILE__)
  load File.expand_path('../lib/discourse_voting/category_extension.rb', __FILE__)
  load File.expand_path('../lib/discourse_voting/topic_extension.rb', __FILE__)
  load File.expand_path('../lib/discourse_voting/user_extension.rb', __FILE__)

  reloadable_patch do |plugin|
    CategoriesController.class_eval { prepend DiscourseVoting::CategoriesControllerExtension }
    Category.class_eval { prepend DiscourseVoting::CategoryExtension }
    Topic.class_eval { prepend DiscourseVoting::TopicExtension }
    User.class_eval { prepend DiscourseVoting::UserExtension }

    require_dependency 'post_serializer'
    class ::PostSerializer
      attributes :can_vote

      def include_can_vote?
        object.post_number == 1
      end

      def can_vote
        object.topic&.can_vote?
      end
    end

    require_dependency 'topic_view_serializer'
    class ::TopicViewSerializer
      attributes :can_vote, :vote_count, :user_voted

      def can_vote
        object.topic.can_vote?
      end

      def vote_count
        object.topic.vote_count
      end

      def user_voted
        scope.user ? object.topic.user_voted?(scope.user) : false
      end
    end

    if TopicQuery.respond_to?(:results_filter_callbacks)
      TopicQuery.results_filter_callbacks << ->(_type, result, user, options) {
        result = result.includes(:topic_vote_count)

        if user
          result = result.select("topics.*, COALESCE((SELECT 1 FROM discourse_voting_votes WHERE user_id = #{user.id} AND topic_id = topics.id), 0) AS current_user_voted")

          if options[:state] == "my_votes"
            result = result.joins("INNER JOIN discourse_voting_votes ON discourse_voting_votes.topic_id = topics.id AND discourse_voting_votes.user_id = #{user.id}")
          end
        end

        if options[:order] == "votes"
          sort_dir = (options[:ascending] == "true") ? "ASC" : "DESC"
          result = result
            .joins("LEFT JOIN discourse_voting_topic_vote_count ON discourse_voting_topic_vote_count.topic_id = topics.id")
            .reorder("COALESCE(discourse_voting_topic_vote_count.votes_count,'0')::integer #{sort_dir}")
        end

        result
      }
    end

    add_to_serializer(:category, :custom_fields) do
      object.custom_fields.merge(enable_topic_voting: DiscourseVoting::CategorySetting.find_by(category_id: object.id).present?)
    end

    add_to_serializer(:topic_list_item, :vote_count) { object.vote_count }
    add_to_serializer(:topic_list_item, :can_vote) { object.can_vote? }
    add_to_serializer(:topic_list_item, :user_voted) { object.user_voted?(scope.user) if scope.user }
    add_to_serializer(:basic_category, :can_vote, false) { SiteSetting.voting_enabled }
    add_to_serializer(:basic_category, :include_can_vote?) { Category.can_vote?(object.id) }

    register_search_advanced_filter(/^min_vote_count:(\d+)$/) do |posts, match|
      posts.where("(SELECT votes_count FROM discourse_voting_topic_vote_count WHERE discourse_voting_topic_vote_count.topic_id = posts.topic_id) >= ?", match.to_i)
    end

    register_search_advanced_order(:votes) do |posts|
      posts.reorder("COALESCE((SELECT dvtvc.votes_count FROM discourse_voting_topic_vote_count dvtvc WHERE dvtvc.topic_id = topics.id), 0) DESC")
    end

    class ::Category
      def self.reset_voting_cache
        @allowed_voting_cache["allowed"] =
          begin
            DiscourseVoting::CategorySetting.pluck(:category_id)
          end
      end

      @allowed_voting_cache = DistributedCache.new("allowed_voting")

      def self.can_vote?(category_id)
        return false unless SiteSetting.voting_enabled

        unless set = @allowed_voting_cache["allowed"]
          set = reset_voting_cache
        end
        set.include?(category_id)
      end

      after_save :reset_voting_cache

      protected
      def reset_voting_cache
        ::Category.reset_voting_cache
      end
    end

    require_dependency 'user'
    class ::User
      def vote_count
        topics_with_vote.length
      end

      def alert_low_votes?
        (vote_limit - vote_count) <= SiteSetting.voting_alert_votes_left
      end

      def topics_with_vote
        self.votes.where(archive: false)
      end

      def topics_with_archived_vote
        self.votes.where(archive: true)
      end

      def reached_voting_limit?
        vote_count >= vote_limit
      end

      def vote_limit
        SiteSetting.public_send("voting_tl#{self.trust_level}_vote_limit")
      end
    end

    require_dependency 'current_user_serializer'
    class ::CurrentUserSerializer
      attributes :votes_exceeded,  :vote_count, :votes_left

      def votes_exceeded
        object.reached_voting_limit?
      end

      def vote_count
        object.vote_count
      end

      def votes_left
        [object.vote_limit - object.vote_count, 0].max
      end
    end

    require_dependency 'list_controller'
    class ::ListController
      def voted_by
        unless SiteSetting.voting_show_votes_on_profile
          render nothing: true, status: 404
        end
        list_opts = build_topic_list_options
        target_user = fetch_user_from_params(include_inactive: current_user.try(:staff?))
        list = generate_list_for("voted_by", target_user, list_opts)
        list.more_topics_url = url_for(construct_url_with(:next, list_opts))
        list.prev_topics_url = url_for(construct_url_with(:prev, list_opts))
        respond_with_list(list)
      end
    end

    require_dependency 'topic_query'
    class ::TopicQuery
      def list_voted_by(user)
        create_list(:user_topics) do |topics|
          topics
            .joins("INNER JOIN discourse_voting_votes ON discourse_voting_votes.topic_id = topics.id")
            .where("discourse_voting_votes.user_id = ?", user.id)
        end
      end

      def list_votes
        create_list(:votes, unordered: true) do |topics|
          topics.joins("LEFT JOIN discourse_voting_topic_vote_count dvtvc ON dvtvc.topic_id = topics.id")
            .order("COALESCE(dvtvc.votes_count,'0')::integer DESC, topics.bumped_at DESC")
        end
      end
    end

    require_dependency "jobs/base"
    module ::Jobs

      class VoteRelease < ::Jobs::Base
        def execute(args)
          if topic = Topic.with_deleted.find_by(id: args[:topic_id])
            votes = DiscourseVoting::Vote.where(topic_id: args[:topic_id])
            votes.update_all(archive: true)

            topic.update_vote_count

            return if args[:trashed]

            votes.find_each do |vote|
              Notification.create!(user_id: vote.user_id,
                                   notification_type: Notification.types[:votes_released],
                                   topic_id: vote.topic_id,
                                   data: { message: "votes_released",
                                           title: "votes_released" }.to_json)
            rescue
              # If one notifcation crash, inform others
            end

          end
        end
      end

      class VoteReclaim < ::Jobs::Base
        def execute(args)
          if topic = Topic.with_deleted.find_by(id: args[:topic_id])
            ActiveRecord::Base.transaction do
              DiscourseVoting::Vote.where(topic_id: args[:topic_id]).update_all(archive: false)
              topic.update_vote_count
            end
          end
        end
      end

    end
  end

  DiscourseEvent.on(:topic_status_updated) do |topic, status, enabled|
    if (status == 'closed' || status == 'autoclosed' || status == 'archived') && enabled == true
      Jobs.enqueue(:vote_release, topic_id: topic.id)
    end

    if (status == 'closed' || status == 'autoclosed' || status == 'archived') && enabled == false
      Jobs.enqueue(:vote_reclaim, topic_id: topic.id)
    end
  end

  DiscourseEvent.on(:topic_trashed) do |topic|
    Jobs.enqueue(:vote_release, topic_id: topic.id, trashed: true) if !topic.closed && !topic.archived
  end

  DiscourseEvent.on(:topic_recovered) do |topic|
    Jobs.enqueue(:vote_reclaim, topic_id: topic.id) if !topic.closed && !topic.archived
  end

  DiscourseEvent.on(:post_edited) do |post, topic_changed|
    if topic_changed &&
        SiteSetting.voting_enabled &&
        DiscourseVoting::Vote.exists?(topic_id: post.topic_id)
      new_category_id = post.reload.topic.category_id
      if Category.can_vote?(new_category_id)
        Jobs.enqueue(:vote_reclaim, topic_id: post.topic_id)
      else
        Jobs.enqueue(:vote_release, topic_id: post.topic_id)
      end
    end
  end

  DiscourseEvent.on(:topic_merged) do |orig, dest|
    moved_votes = 0
    duplicated_votes = 0

    if orig.who_voted.present? && orig.closed
      orig.who_voted.each do |user|
        next if user.blank?

        user_votes = user.topics_with_vote.pluck(:topic_id)
        user_archived_votes = user.topics_with_archived_vote.pluck(:topic_id)

        if user_votes.include?(orig.id) || user_archived_votes.include?(orig.id)
          if user_votes.include?(dest.id) || user_archived_votes.include?(dest.id)
            duplicated_votes += 1
            user.votes.destroy_by(topic_id: orig.id)
          else
            user.votes.find_by(topic_id: orig.id, user_id: user.id).update!(topic_id: dest.id, archive: dest.closed)
            moved_votes += 1
          end
        else
          next
        end
      end
    end

    if moved_votes > 0
      orig.update_vote_count
      dest.update_vote_count

      if moderator_post = orig.ordered_posts.where(action_code: 'split_topic').last
        moderator_post.raw << "\n\n#{I18n.t('voting.votes_moved', count: moved_votes)}"
        moderator_post.raw << " #{I18n.t('voting.duplicated_votes', count: duplicated_votes)}" if duplicated_votes > 0
        moderator_post.save!
      end
    end
  end

  require File.expand_path(File.dirname(__FILE__) + '/app/controllers/discourse_voting/votes_controller')

  DiscourseVoting::Engine.routes.draw do
    post 'vote' => 'votes#vote'
    post 'unvote' => 'votes#unvote'
    get 'who' => 'votes#who'
  end

  Discourse::Application.routes.append do
    mount ::DiscourseVoting::Engine, at: "/voting"
    # USERNAME_ROUTE_FORMAT is deprecated but we may need to support it for older installs
    username_route_format = defined?(RouteFormat) ? RouteFormat.username : USERNAME_ROUTE_FORMAT
    get "topics/voted-by/:username" => "list#voted_by", as: "voted_by", constraints: { username: username_route_format }
  end
end
