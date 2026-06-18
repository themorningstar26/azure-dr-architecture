location              = "westeurope"  # ONLY difference from primary
node_count            = 2             # warm standby — HPA scales on failover
node_sku              = "Standard_D2s_v3"

# Fill after primary deploy:
# primary_sql_server_id = "/subscriptions/.../sql-myapp-primary"
