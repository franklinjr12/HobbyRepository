class Team < ApplicationRecord
  has_many :team_memberships, dependent: :destroy
  has_many :users, through: :team_memberships
  has_many :apps, dependent: :restrict_with_error

  before_validation :normalize_slug

  validates :name, :slug, presence: true
  validates :slug, uniqueness: true,
                   format: {
                     with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/,
                     message: "must use lowercase letters, numbers, and hyphens"
                   }

  def membership_for(user)
    team_memberships.find_by(user: user)
  end

  private

  def normalize_slug
    self.slug = slug.to_s.parameterize if slug.present?
    self.slug = name.to_s.parameterize if slug.blank? && name.present?
  end
end
