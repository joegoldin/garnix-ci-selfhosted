{
  name = "test monitoring server node";

  nodes.server = { config, lib, ... }: {
    garnix.monitoring-server.enable = true;
  };

  testScript = { nodes, ... }: ''
    start_all()
    server.wait_for_unit("multi-user.target")
    server.wait_for_unit("nginx.service")
    server.wait_for_unit("prometheus.service")
    server.wait_for_unit("grafana.service")
    server.wait_for_unit("watchdog.service")

    server.wait_until_succeeds("curl --fail-with-body http://localhost/login", timeout=30)
  '';
}
