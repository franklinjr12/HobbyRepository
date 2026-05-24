class AppScheduler
  Placement = Data.define(:node, :reason, :metadata)

  def place(app, reason:)
    node = Node.ensure_local!
    previous_node_id = app.node_id

    app.update!(node: node) if app.node != node
    placement = Placement.new(
      node,
      "local_node",
      {
        scheduler: self.class.name,
        reason: reason,
        previous_node_id: previous_node_id,
        node_id: node.id,
        node_hostname: node.hostname
      }.compact
    )

    app.record_event!(
      "scheduler.placement_selected",
      "Scheduler selected #{node.name} for #{app.name}",
      metadata: placement.metadata
    )
    placement
  end
end
