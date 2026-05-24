module Admin
  class TeamsController < BaseController
    before_action :set_team, only: %i[edit update destroy]

    def index
      @teams = Team.includes(:team_memberships, :apps).order(:name)
    end

    def new
      @team = Team.new
    end

    def edit
      @users = User.order(:email)
      @memberships = @team.team_memberships.includes(:user).order("users.email")
    end

    def create
      @team = Team.new(team_params)

      if @team.save
        redirect_to edit_admin_team_path(@team), notice: "#{@team.name} was created."
      else
        render :new, status: :unprocessable_content
      end
    end

    def update
      if @team.update(team_params)
        redirect_to edit_admin_team_path(@team), notice: "#{@team.name} was updated."
      else
        @users = User.order(:email)
        @memberships = @team.team_memberships.includes(:user).order("users.email")
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      team_name = @team.name
      @team.destroy!
      redirect_to admin_teams_path, notice: "#{team_name} was deleted."
    rescue ActiveRecord::DeleteRestrictionError, ActiveRecord::RecordNotDestroyed => error
      redirect_to edit_admin_team_path(@team), alert: error.message
    end

    private

    def set_team
      @team = Team.find(params.expect(:id))
    end

    def team_params
      params.expect(team: %i[name slug])
    end
  end
end
