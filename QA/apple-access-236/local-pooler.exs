{:ok, _} = Application.ensure_all_started(:supavisor)

params = %{
  "external_id" => "repair235",
  "db_host" => System.get_env("POSTGRES_HOST"),
  "db_port" => 5432,
  "db_database" => System.get_env("POSTGRES_DB"),
  "require_user" => true,
  "default_max_clients" => 100,
  "default_pool_size" => 3,
  "default_parameter_status" => %{"server_version" => "17.11"},
  "users" => [%{
    "db_user" => "postgres",
    "db_password" => System.get_env("POSTGRES_PASSWORD"),
    "mode_type" => "transaction",
    "pool_size" => 3,
    "is_manager" => true
  }]
}

if !Supavisor.Tenants.get_tenant_by_external_id("repair235") do
  {:ok, _} = Supavisor.Tenants.create_tenant(params)
end
