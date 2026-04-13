package main

import (
	_ "embed"
	"fmt"
	"os"

	oplog "github.com/ethereum-optimism/optimism/op-service/log"
	"github.com/ethereum/go-ethereum/log"
	"github.com/urfave/cli/v2"
)

var (
	Version   = "v0.0.1"
	GitCommit = ""
	GitDate   = ""
)

//go:embed embed/docker-compose.yml
var dockerComposeTemplate string

//go:embed embed/replayor.docker.env.example
var replayorDockerEnvTemplate string

//go:embed embed/reth.docker.env.example
var rethDockerEnvTemplate string

//go:embed embed/unwind.sh
var unwindShTemplate string

//go:embed embed/reth.sh
var rethShTemplate string

//go:embed embed/replayor.sh
var replayorShTemplate string

//go:embed embed/Dockerfile
var dockerfileTemplate string

func main() {
	oplog.SetupDefaults()
	app := cli.NewApp()
	app.Version = fmt.Sprintf("%s-%s-%s", Version, GitCommit, GitDate)
	app.Name = "multi-replayor"
	app.Description = "Utility to schedule and run multiple replayor instances in parallel using docker-compose"
	app.Commands = []*cli.Command{
		RunCommand(),
		GenTemplateCommand(),
	}

	err := app.Run(os.Args)
	if err != nil {
		log.Crit("Application failed", "message", err)
		os.Exit(1)
	}
}
