#
# Mailer that sends out the daily digests of page updates
#
# This is triggered from a chron job. At night in the early morning.
# It includes all updates from the day before. In order to ensure
# consistency please make sure deliver_all finishes on the same day it
# started.

class Mailer::DailyDigest < ActionMailer::Base

  TIMESPAN = 1.day

  add_template_helper(Pages::HistoryHelper)
  add_template_helper(Common::Utility::TimeHelper)

  def self.deliver_all
    digest_recipients.map do |recipient|
      # let's throttle this a bit. We have ~2000 recipients
      # So this will take 2000 sec. < 40 Minutes total.
      sleep 1
      page_digest(recipient).deliver
    end.tap do
      mark_all_as_send
    end
  end

  def self.digest_recipients
    User.where(receive_notifications: 'Digest')
  end

  def self.mark_all_as_send
    page_histories.update_all notification_digest_sent_at: Time.now
  end

  def page_digest(recipient)
    @recipient = recipient
    @site = Site.default || Site.new
    @histories = self.class.page_histories.
      where(page_id: updated_pages).
      includes(:page).
      order(:page_id, "page_histories.created_at")
    return if @histories.blank?
    mail to: recipient,
      subject: I18n.t("mail.subject.daily_digest", site: @site.title),
      from: @site.email_sender.gsub('$current_host', @site.domain)
  end

  protected

  def self.page_histories
    PageHistory.where(notification_digest_sent_at: nil).
      where("DATE(page_histories.created_at) >= DATE(?)", TIMESPAN.ago).
      where("DATE(page_histories.created_at) < DATE(?)", Time.now)
  end

  def updated_pages
    Page.joins(:user_participations).
      where(user_participations: {user_id: @recipient}).
      where(user_participations: {watch: true}).
      where("DATE(pages.updated_at) >= DATE(?)", TIMESPAN.ago)
  end

end
