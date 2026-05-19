class AppEvent < ApplicationRecord
  belongs_to :app

  validates :event_type, :message, presence: true

  def metadata_summary
    metadata.to_h.except("error", "stderr").map { |key, value| "#{key}: #{value}" }.join(", ")
  end

  def related_runtime_instance_id
    metadata.to_h["runtime_instance_id"] || metadata.to_h.dig("error", "runtime_instance_id")
  end
end
