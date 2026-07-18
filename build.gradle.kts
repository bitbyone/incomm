// Root aggregator build. All real configuration lives in :plugin.
// The Go CLI is built separately with `go build` inside ./cli.

group = providers.gradleProperty("pluginGroup").getOrElse("dev.incomm")
version = providers.gradleProperty("pluginVersion").getOrElse("0.1.0")
