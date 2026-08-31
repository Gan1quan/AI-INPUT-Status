struct ServiceGroup: Identifiable {
    let name: String
    let services: [ServiceStatus]
    var id: String { name }
}

