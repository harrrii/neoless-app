import Foundation
import NeolessHubKit

// neoless-hub: the processing hub on the Neo (docs/hub.md). Everything lives in NeolessHubKit; this only runs it.
setvbuf(stdout, nil, _IOLBF, 0)
exit(await HubCommands.main(Array(CommandLine.arguments.dropFirst())))
