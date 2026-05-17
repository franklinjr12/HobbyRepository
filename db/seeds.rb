# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

Node.ensure_local!

User.find_or_create_by!(email: ENV.fetch("SEED_USER_EMAIL", "admin@example.com")) do |user|
  user.name = "Platform Admin"
  user.password = ENV.fetch("SEED_USER_PASSWORD", "password123")
  user.admin = true
end
