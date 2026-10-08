#!/usr/bin/env bash
# Builds release assets into dist/ with the names install.sh downloads:
#   XrayW-linux-<arch>.gz        full build (every lego DNS provider)
#   XrayW-linux-<arch>-lite.gz   lite build (6 DNS providers, embedded fallback roots)
#   SHA256SUMS                   checksums of everything above
#
# Usage: bash release/build.sh v1.0.0 [arch ...]   (default: all architectures)
set -euo pipefail
version="${1:-dev}"
shift || true
cd "$(dirname "$0")/.."

# name:GOARCH:extra env (softfloat: routers rarely have an FPU)
targets=(
	"amd64:amd64:"
	"386:386:GO386=softfloat"
	"arm64:arm64:"
	"armv7:arm:GOARM=7"
	"armv6:arm:GOARM=6"
	"armv5:arm:GOARM=5"
	"mips:mips:GOMIPS=softfloat"
	"mipsle:mipsle:GOMIPS=softfloat"
	"mips64:mips64:GOMIPS64=softfloat"
	"mips64le:mips64le:GOMIPS64=softfloat"
	"riscv64:riscv64:"
	"loong64:loong64:"
)
want=("$@")

mod=github.com/W1nCwC/XrayW
rm -rf dist
mkdir -p dist
for t in "${targets[@]}"; do
	IFS=: read -r name goarch extra <<<"$t"
	if [ ${#want[@]} -gt 0 ] && [[ ! " ${want[*]} " =~ " $name " ]]; then
		continue
	fi
	for flavor in full lite; do
		tags=""
		suffix=""
		if [ "$flavor" = lite ]; then
			tags="dnslite,fallbackroots"
			suffix="-lite"
		fi
		out="dist/XrayW-linux-$name$suffix"
		echo "build $out"
		env CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" ${extra:+"$extra"} \
			go build -trimpath -tags "$tags" \
			-ldflags "-s -w -X $mod/cmd.version=$version" -o "$out" .
		gzip -9 -n -f "$out"
	done
done
(cd dist && sha256sum -- * | grep -v ' SHA256SUMS$' >SHA256SUMS)
ls -l dist
