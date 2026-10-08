package cmd

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/W1nCwC/XrayW/migrate"
)

var migrateOpts migrate.Options

func init() {
	c := &cobra.Command{
		Use:   "migrate",
		Short: "Convert an XrayR installation into an XrayW config (XrayR files are only read)",
		RunE: func(cmd *cobra.Command, args []string) error {
			r, err := migrate.Run(migrateOpts)
			if r != nil {
				fmt.Print(r.String())
			}
			if err != nil {
				return err
			}
			if migrateOpts.DryRun {
				fmt.Println("（dry-run：未写入任何文件）")
			} else {
				fmt.Printf("迁移完成。请执行 `XrayW check -c %s --online` 检查\n", r.Config)
			}
			return nil
		},
	}
	c.Flags().StringVar(&migrateOpts.From, "from", "/etc/XrayR", "XrayR directory or config.yml")
	c.Flags().StringVar(&migrateOpts.To, "to", "/etc/XrayW", "XrayW directory")
	c.Flags().BoolVar(&migrateOpts.DryRun, "dry-run", false, "only print what would be done")
	c.Flags().BoolVar(&migrateOpts.Force, "force", false, "overwrite existing files in the target directory")
	rootCmd.AddCommand(c)
}
