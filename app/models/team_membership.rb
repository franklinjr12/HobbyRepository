class TeamMembership < ApplicationRecord
  ROLES = %w[viewer developer admin owner].freeze
  WRITE_ROLES = %w[developer admin owner].freeze
  ADMIN_ROLES = %w[admin owner].freeze

  belongs_to :team
  belongs_to :user

  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :team_id }

  def can_manage_apps?
    role.in?(WRITE_ROLES)
  end

  def can_administer_team?
    role.in?(ADMIN_ROLES)
  end
end
