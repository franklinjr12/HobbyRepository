module Admin
  class TeamMembershipsController < BaseController
    before_action :set_team
    before_action :set_membership, only: %i[update destroy]

    def create
      membership = @team.team_memberships.find_or_initialize_by(user_id: membership_params.fetch(:user_id))
      membership.role = membership_params.fetch(:role)
      membership.save!

      redirect_to edit_admin_team_path(@team), notice: "#{membership.user.email} was added to #{@team.name}."
    rescue ActiveRecord::RecordInvalid => error
      redirect_to edit_admin_team_path(@team), alert: error.record.errors.full_messages.to_sentence
    end

    def update
      @membership.update!(role: membership_params.fetch(:role))

      redirect_to edit_admin_team_path(@team), notice: "#{@membership.user.email} role was updated."
    rescue ActiveRecord::RecordInvalid => error
      redirect_to edit_admin_team_path(@team), alert: error.record.errors.full_messages.to_sentence
    end

    def destroy
      user_email = @membership.user.email
      @membership.destroy!

      redirect_to edit_admin_team_path(@team), notice: "#{user_email} was removed from #{@team.name}."
    end

    private

    def set_team
      @team = Team.find(params.expect(:team_id))
    end

    def set_membership
      @membership = @team.team_memberships.find(params.expect(:id))
    end

    def membership_params
      params.expect(team_membership: %i[user_id role])
    end
  end
end
