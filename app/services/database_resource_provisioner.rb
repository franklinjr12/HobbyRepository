class DatabaseResourceProvisioner
  Result = Data.define(:success, :message) do
    alias success? success
  end

  def initialize(connection: ActiveRecord::Base.connection)
    @connection = connection
  end

  def provision(database_resource)
    database_resource.update!(status: "provisioning", failure_message: nil)
    create_database(database_resource)
    create_user(database_resource)
    grant_access(database_resource)
    database_resource.mark_provisioned!
    Result.new(true, "Database provisioned.")
  rescue ActiveRecord::StatementInvalid => error
    database_resource.mark_failed!(error.message)
    Result.new(false, error.message)
  end

  private

  attr_reader :connection

  def create_database(database_resource)
    connection.execute("CREATE DATABASE #{quote_identifier(database_resource.database_name)}")
  rescue ActiveRecord::StatementInvalid => error
    raise unless error.message.match?(/already exists/i)
  end

  def create_user(database_resource)
    connection.execute(<<~SQL.squish)
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = #{connection.quote(database_resource.username)}) THEN
          CREATE USER #{quote_identifier(database_resource.username)} WITH PASSWORD #{connection.quote(database_resource.password)};
        ELSE
          ALTER USER #{quote_identifier(database_resource.username)} WITH PASSWORD #{connection.quote(database_resource.password)};
        END IF;
      END
      $$;
    SQL
  end

  def grant_access(database_resource)
    connection.execute(<<~SQL.squish)
      GRANT ALL PRIVILEGES ON DATABASE #{quote_identifier(database_resource.database_name)}
      TO #{quote_identifier(database_resource.username)}
    SQL
  end

  def quote_identifier(identifier)
    connection.quote_table_name(identifier)
  end
end
