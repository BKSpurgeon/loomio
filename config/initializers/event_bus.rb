require 'event_bus'

EventBus.configure do |config|

  config.listen('new_comment_event',
                'new_discussion_event',
                'discussion_edited_event',
                'poll_created_event',
                'poll_edited_event',
                'stance_created_event',
                'outcome_created_event',
                'poll_closed_by_user_event') do |event|
    if event.discussion
      reader = DiscussionReader.for_model(event.discussion, event.user)
                               .update_reader(ranges: event.sequence_id,
                                              volume: :loud)
      MessageChannelService.publish_data(ActiveModel::ArraySerializer.new([reader],
                                         each_serializer: DiscussionReaderSerializer,
                                         root: :discussions).as_json,
                                         to: reader.message_channel)
    end
  end

  # Purge drafts after model creation
  config.listen('group_create',
                'discussion_create',
                'comment_create',
                'poll_create') { |model, actor| model.perform_draft_purge!(actor) }

  # Add creator to group on group creation
  config.listen('group_create') do |group, actor|
    if actor.is_logged_in?
      group.add_admin! actor
    elsif actor.email.present?
      InvitationService.invite_creator_to_group(group: group, creator: actor)
    end
  end

  # Index search vectors after model creation
  config.listen('discussion_create',
                'discussion_update',
                'motion_create',
                'motion_update',
                'comment_create',
                'comment_update',
                'poll_create',
                'poll_update') { |model| SearchVector.index! model.discussion_id }

  # add poll creator as admin of guest group
  config.listen('poll_create') { |poll, actor| poll.guest_group.add_admin!(actor) }

  # publish to new group if group has changed
  config.listen('poll_changed_group') do |poll, actor|
    poll.make_announcement = true
    Events::PollCreated.publish!(poll, actor)
  end

  # mark invitations with the new user's email as used
  config.listen('user_added_to_group_event', 'user_joined_group_event') do |event|
    event.eventable.group.invitations.pending
         .where(recipient_email: event.eventable.user.email)
         .update_all(accepted_at: event.created_at || Time.now)
  end

  # add creator to group if one doesn't exist
  config.listen('membership_join_group') { |group, actor| group.update(creator: actor) unless group.creator_id.present? }

  # send memos to client side after comment change
  config.listen('comment_destroy')  { |comment|  Memos::CommentDestroyed.publish!(comment) }
  config.listen('reaction_destroy') { |reaction| Memos::ReactionDestroyed.publish!(reaction: reaction) }


  config.listen('event_remove_from_thread') do |event|
    MessageChannelService.publish_model(event, serializer: Events::BaseSerializer)
  end

  config.listen('discussion_mark_as_read',
                'discussion_dismiss',
                'discussion_mark_as_seen') do |reader|
    MessageChannelService.publish_data(ActiveModel::ArraySerializer.new([reader], each_serializer: DiscussionReaderSerializer, root: :discussions).as_json, to: reader.message_channel)
  end

  config.listen('discussion_mark_as_seen') do |reader|
    MessageChannelService.publish_model(reader.discussion)
  end

  # alert clients that notifications have been read
  config.listen('notification_viewed') do |actor|
    MessageChannelService.publish_data(NotificationCollection.new(actor).serialize!, to: actor.message_channel)
  end

  # update discussion or comment versions_count when title or description edited
  config.listen('discussion_update', 'comment_update') { |model| model.update_versions_count }

  # update stance data for polls
  config.listen('stance_create')  { |stance| stance.poll.update_stance_data }

  # publish reply event after comment creation
  config.listen('comment_create') { |comment| Events::CommentRepliedTo.publish!(comment) }

  # publish mention events after model create / update
  config.listen('comment_create',
                'comment_update',
                'motion_create',
                'motion_update',
                'discussion_create',
                'discussion_update') do |model, actor|
    Queries::UsersToMentionQuery.for(model).each { |user| Events::UserMentioned.publish!(model, actor, user) }
  end

  # update discussion importance
  config.listen('discussion_pin',
                'poll_create',
                'poll_close',
                'poll_destroy',
                'poll_expire') { |model| model.discussion&.update_importance }

  # nullify parent_id on children of destroyed comment
  config.listen('comment_destroy') { |comment| Comment.where(parent_id: comment.id).update_all(parent_id: nil) }

  # collect user deactivation response
  config.listen('user_deactivate') { |user, actor, params| UserDeactivationResponse.create(user: user, body: params[:deactivation_response]) }
end
