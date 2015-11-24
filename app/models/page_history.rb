class PageHistory < ActiveRecord::Base
  belongs_to :user
  belongs_to :page
  belongs_to :item, polymorphic: true

  validates_presence_of :user, :page

  serialize :details, Hash

  after_create :send_single_pending_notifications

  def send_single_pending_notifications
    destroy && return if page.nil?
    recipients_for_single_notification.each do |user|
      if Conf.paranoid_emails?
        Mailer.page_history_single_notification_paranoid(user, self).deliver
      else
        Mailer.page_history_single_notification(user, self).deliver
      end
    end
    update_attribute :notification_sent_at, Time.now
  end
  handle_asynchronously :send_single_pending_notifications

  # BROKEN RIGHT NOW:
  # This used to be far to complex for processing the backlog of
  # unsend notifications we have in production.
  #
  # I rewrote this to only work on a single page. But that does not
  # get us very far either.
  #
  # One of the issues involved is how to send a batch of notifications
  # for different pages each having some page_histories.
  #
  # Here's the plan...
  # * get all the page_histories grouped by page
  #   (which effectively will get us one per page)
  # * call this method on all of them. It sends digests for all the
  #   page_histories for the given page within the last 24 hours.
  #
  # So for now we only send single notifications
  def send_digest_pending_notifications
    return #FIXME
    page_histories = PageHistory.digested_with(self).pending_notifications
    recipients_for_digest_notifications.each do |user|
      if Conf.paranoid_emails?
        Mailer.page_history_digest_notification_paranoid(user, page, page_histories).deliver
      else
        Mailer.page_history_digest_notification(user, page, page_histories).deliver
      end
    end
    page_histories.update_all notification_digest_sent_at: Time.now
  end

  def self.digested_with(page_history)
    where(page_id: page_history.page_id).
      where("created_at > #{page_history.created_at - 1.day}").
      where("created_at < #{page_history.created_at + 1.day}")
  end

  def self.pending_notifications
    where notification_sent_at: nil
  end

  def recipients_for_page
    UserParticipation.where(page_id: page.id, watch: true).pluck(:user_id)
  end

  def recipients_for_digest_notifications
    User.where receive_notifications: 'Digest', id: recipients_for_page
  end

  def recipients_for_single_notification
    users_watching_ids = recipients_for_page
    users_watching_ids.delete(user.id)
    User.where receive_notifications: 'Single',
      id: users_watching_ids
  end

  def description_key
    self.class.name.underscore.gsub('/', '_')
  end

  # params to substitute in the translation of the description key
  def description_params
    { user_name: user_name, item_name: item_name }
  end

  def user_name
    user.try.display_name || "Unknown/Deleted"
  end

  def item_name
    case item
    when Group then item.full_name
    when User then item.display_name
    else "Unknown/Deleted"
    end
  end


  # no details by default
  def details_key; end

  protected

  def page_updated_at
    Page.update_all(["updated_at = ?", created_at], ["id = ?", page.id])
  end
end

# Factory class for the different page updates
class PageHistory::Update < PageHistory
  def self.pick_class(attrs = {})
    class_for_update(attrs[:page])
  end

  protected

  def self.class_for_update(page)
    return PageHistory::MakePrivate if page.marked_as_private?
    return PageHistory::MakePublic if page.marked_as_public?
    # return PageHistory::ChangeOwner if page.owner_id_changed?
  end
end
class PageHistory::MakePublic     < PageHistory; end
class PageHistory::MakePrivate    < PageHistory; end

class PageHistory::PageCreated < PageHistory
  after_save :page_updated_at

  def description_key
    :page_history_user_created_page
  end
end

class PageHistory::ChangeTitle < PageHistory
  before_save :add_details
  after_save :page_updated_at

  def add_details
    self.details = details_from_page
  end

  def details_key
    :page_history_details_change_title
  end

  def details_from_page
    {
      from: page.previous_changes["title"].first,
      to: page.title
    }
  end
end

class PageHistory::Deleted < PageHistory
  after_save :page_updated_at

  def description_key
    :page_history_deleted_page
  end
end

class PageHistory::UpdatedContent < PageHistory
  after_save :page_updated_at
end

# Factory class for the different page updates
# To track updates to participations:
#  * inherit directly from this class
#  * define self.tracks on your class to return true for changes that should
#    be tracked.
# Changes will be a ActiveModel::Dirty changeset. You can use the activated
# and deactivated helper methods if you only need to look at the boolean value.
class PageHistory::UpdateParticipation < PageHistory
  def self.pick_class(attrs = {})
    class_for_update(attrs[:participation])
  end

  protected

  def self.class_for_update(participation)
    subclasses.detect{|klass|
      klass.tracks participation.previous_changes, participation
    }
  end

  def self.tracks(changes, part); false; end

  def self.activated(old = nil, new = nil)
    new && !old
  end

  def self.deactivated(old = nil, new = nil)
    old && !new
  end
end

class PageHistory::AddStar < PageHistory::UpdateParticipation
  def self.tracks(changes, _part)
    activated(*changes[:star])
  end
end

class PageHistory::RemoveStar < PageHistory::UpdateParticipation
  def self.tracks(changes, _part)
    deactivated(*changes[:star])
  end
end

class PageHistory::StartWatching  < PageHistory::UpdateParticipation
  def self.tracks(changes, _part)
    activated(*changes[:watch])
  end
end

class PageHistory::StopWatching  < PageHistory::UpdateParticipation
  def self.tracks(changes, _part)
    deactivated(*changes[:watch])
  end
end

# Module for the methods shared between
# GrantGroupAccess and GrantUserAccess.
module PageHistory::GrantAccess
  extend ActiveSupport::Concern

  def participation=(part)
    self.access = access_from_participation(part)
  end

  # participations use a different naming scheme for access levels
  # TODO: unify these.
  ACCESS_FROM_PARTICIPATION_SYM = {
    view:  :read,
    edit:  :write,
    admin: :full
  }
  def access_from_participation(participation = nil)
    ACCESS_FROM_PARTICIPATION_SYM[participation.try.access_sym]
  end

  def description_key
    key = super
    key.sub!('grant', 'granted')
  end

  def access
    details[:access]
  end

  def access=(value)
    self.details ||= {}
    self.details[:access] = value
  end
end

class PageHistory::GrantGroupAccess < PageHistory::UpdateParticipation
  include GrantAccess

  def self.tracks(changes, part)
    part.is_a?(GroupParticipation) && changes.keys.include?('access')
  end

  after_save :page_updated_at

  validates_presence_of :item_id
  validates_format_of :item_type, with: /Group/

  def participation=(part)
    self.item = part.try.group
    super
  end

  def description_key
    access.blank? ? super : super.sub('group_access', "group_#{access}_access")
  end
end

#
# DEPRECATED:
#
# please use PageHistory::GrantGroupAccess and hand in the participation
# to determine the level of access.
class PageHistory::GrantGroupFullAccess < PageHistory::GrantGroupAccess; end
class PageHistory::GrantGroupWriteAccess < PageHistory::GrantGroupAccess; end
class PageHistory::GrantGroupReadAccess < PageHistory::GrantGroupAccess; end

class PageHistory::RevokedGroupAccess < PageHistory::UpdateParticipation
  after_save :page_updated_at

  def self.tracks(changes, part)
    part.is_a?(GroupParticipation) &&
      !GroupParticipation.exists?(id: part.id)
  end

  def participation=(part)
    self.item = part.try.group
  end

  validates_format_of :item_type, with: /Group/
  validates_presence_of :item_id
end

class PageHistory::GrantUserAccess < PageHistory::UpdateParticipation
  include GrantAccess

  def self.tracks(changes, part)
    part.is_a?(UserParticipation) && changes.keys.include?('access')
  end

  after_save :page_updated_at

  validates_presence_of :item_id
  validates_format_of :item_type, with: /User/

  def participation=(part)
    self.item = part.try.user
    super
  end

  def description_key
    access.blank? ? super : super.sub('user_access', "user_#{access}_access")
  end
end

#
# DEPRECATED:
#
# please use PageHistory::GrantUserAccess and hand in the participation
# to determine the level of access.
class PageHistory::GrantUserFullAccess < PageHistory::GrantUserAccess; end
class PageHistory::GrantUserWriteAccess < PageHistory::GrantUserAccess; end
class PageHistory::GrantUserReadAccess < PageHistory::GrantUserAccess; end

class PageHistory::RevokedUserAccess < PageHistory::UpdateParticipation
  def self.tracks(changes, part)
    part.is_a?(UserParticipation) &&
      !UserParticipation.exists?(id: part.id)
  end

  def participation=(part)
    self.item = part.try.user
  end

  after_save :page_updated_at

  validates_format_of :item_type, with: /User/
  validates_presence_of :item_id
end

class PageHistory::ForComment < PageHistory
  after_save :page_updated_at

  validates_format_of :item_type, with: /Post/
  validates_presence_of :item_id

  # use past tense
  # super still uses the name of the actual class
  def description_key
    super.sub(/e?_comment/, 'ed_comment')
  end
end

class PageHistory::AddComment < PageHistory::ForComment ; end
class PageHistory::UpdateComment < PageHistory::ForComment ; end
class PageHistory::DestroyComment < PageHistory::ForComment ; end
