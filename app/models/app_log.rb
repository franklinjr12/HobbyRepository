require "digest"

class AppLog < ApplicationRecord
  STREAMS = %w[stdout stderr].freeze
  DOCKER_TIMESTAMP_PATTERN = /\A(?<timestamp>\d{4}-\d{2}-\d{2}T\S+)\s(?<message>.*)\z/

  belongs_to :app
  belongs_to :runtime_instance, optional: true
  belongs_to :deployment, optional: true

  before_validation :assign_app_from_runtime_instance
  before_validation :assign_deployment_from_runtime_instance
  before_validation :assign_logged_at
  before_validation :assign_content_hash

  validates :stream, :logged_at, :message, :content_hash, presence: true
  validates :stream, inclusion: { in: STREAMS }
  validates :content_hash, uniqueness: { scope: %i[runtime_instance_id stream logged_at] }

  scope :newest_first, -> { order(logged_at: :desc, id: :desc) }
  scope :recent, ->(limit_count = 200) { newest_first.limit(limit_count) }
  scope :for_runtime_instance, ->(runtime_instance_id) { where(runtime_instance_id: runtime_instance_id) if runtime_instance_id.present? }
  scope :for_deployment, ->(deployment_id) { where(deployment_id: deployment_id) if deployment_id.present? }
  scope :text_search, lambda { |query|
    if query.present?
      where("message ILIKE ?", "%#{sanitize_sql_like(query)}%")
    end
  }

  def self.ingest_docker_output!(app:, runtime_instance:, stdout:, stderr:)
    records = STREAMS.flat_map do |stream|
      parse_stream(stream == "stdout" ? stdout : stderr, stream: stream, fallback_time: Time.current)
    end

    records.each do |attributes|
      create!(
        attributes.merge(
          app: app,
          runtime_instance: runtime_instance,
          deployment: runtime_instance&.deployment
        )
      )
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      next
    end

    records.size
  end

  def self.parse_stream(output, stream:, fallback_time:)
    output.to_s.lines.map do |line|
      parsed = parse_line(line.chomp, fallback_time: fallback_time)
      parsed.merge(stream: stream)
    end
  end

  def self.parse_line(line, fallback_time:)
    match = DOCKER_TIMESTAMP_PATTERN.match(line)
    return { logged_at: fallback_time, message: line } unless match

    {
      logged_at: Time.zone.parse(match[:timestamp]) || fallback_time,
      message: match[:message]
    }
  rescue ArgumentError
    { logged_at: fallback_time, message: line }
  end

  def metadata_label
    [ stream, runtime_instance&.container_id, deployment_id&.then { |id| "deployment ##{id}" } ].compact.join(" - ")
  end

  private

  def assign_app_from_runtime_instance
    self.app ||= runtime_instance&.app
  end

  def assign_deployment_from_runtime_instance
    self.deployment ||= runtime_instance&.deployment
  end

  def assign_logged_at
    self.logged_at ||= Time.current
  end

  def assign_content_hash
    self.content_hash = Digest::SHA256.hexdigest(message.to_s) if message.present?
  end
end
