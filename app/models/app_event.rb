class AppEvent < ApplicationRecord
  belongs_to :app

  validates :event_type, :message, presence: true
end
