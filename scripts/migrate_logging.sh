#!/bin/bash
# Logging Migration Helper Script
#
# This script helps identify and analyze logging patterns that need migration.
# It does NOT perform automated replacement (too risky for complex code).
#
# Usage:
#   ./scripts/migrate_logging.sh analyze      # Show current state
#   ./scripts/migrate_logging.sh batch1       # List Batch 1 files
#   ./scripts/migrate_logging.sh verify       # Check if migration complete

set -euo pipefail

SRC_DIR="src"
EXCLUDE_FILE="util/logging.zig"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print colored message
print_color() {
    local color=$1
    shift
    echo -e "${color}$*${NC}"
}

# Analyze current logging usage
analyze() {
    print_color "$BLUE" "=== Logging Migration Analysis ==="
    echo ""

    print_color "$YELLOW" "📊 Current State:"
    local debug_print_count=$(grep -r "std\.debug\.print" "$SRC_DIR" --include="*.zig" --exclude="$EXCLUDE_FILE" | wc -l | tr -d ' ')
    local std_log_count=$(grep -r "std\.log\." "$SRC_DIR" --include="*.zig" | wc -l | tr -d ' ')

    echo "  std.debug.print instances: $debug_print_count"
    echo "  std.log.* instances:       $std_log_count"
    echo "  Total to migrate:          $((debug_print_count + std_log_count))"
    echo ""

    print_color "$YELLOW" "📁 Files with Mixed Logging:"
    local file_count=$(grep -r "std\.debug\.print\|std\.log\." "$SRC_DIR" --include="*.zig" --exclude="$EXCLUDE_FILE" -l | wc -l | tr -d ' ')
    echo "  Total files: $file_count"
    echo ""

    print_color "$YELLOW" "🔝 Top 10 Files by Instance Count:"
    grep -r "std\.debug\.print\|std\.log\." "$SRC_DIR" --include="*.zig" --exclude="$EXCLUDE_FILE" -h | \
        cut -d: -f1 | sort | uniq -c | sort -rn | head -10
    echo ""
}

# List files in a specific batch
list_batch() {
    local batch=$1

    case $batch in
        1)
            print_color "$GREEN" "Batch 1: Core Modules (8 files)"
            find "$SRC_DIR/main" -name "*.zig" -type f
            echo "$SRC_DIR/client.zig"
            echo "$SRC_DIR/cli.zig"
            ;;
        2)
            print_color "$GREEN" "Batch 2: Server Modules (10 files)"
            find "$SRC_DIR/server" -name "*.zig" -type f -not -path "*/broker/client_manager.zig"
            ;;
        3)
            print_color "$GREEN" "Batch 3: Network Modules (8 files)"
            echo "$SRC_DIR/net/tcp.zig"
            echo "$SRC_DIR/net/udp.zig"
            echo "$SRC_DIR/net/socket.zig"
            echo "$SRC_DIR/net/connection.zig"
            echo "$SRC_DIR/net/allowlist.zig"
            echo "$SRC_DIR/net/unixsock.zig"
            find "$SRC_DIR/net/proxy" -name "*.zig" -type f
            ;;
        4)
            print_color "$GREEN" "Batch 4: I/O Modules (6 files)"
            echo "$SRC_DIR/io/transfer.zig"
            echo "$SRC_DIR/io/output.zig"
            echo "$SRC_DIR/io/hexdump.zig"
            find "$SRC_DIR/io/tls_transfer" -name "*.zig" -type f -not -name "test*.zig"
            ;;
        5)
            print_color "$GREEN" "Batch 5: TLS Modules (5 files)"
            echo "$SRC_DIR/tls/tls.zig"
            echo "$SRC_DIR/tls/tls_openssl.zig"
            echo "$SRC_DIR/tls/tls_config.zig"
            echo "$SRC_DIR/tls/tls_state.zig"
            echo "$SRC_DIR/tls/tls_metrics.zig"
            ;;
        6)
            print_color "$GREEN" "Batch 6: Utilities (4 files)"
            echo "$SRC_DIR/util/security.zig"
            echo "$SRC_DIR/util/portscan.zig"
            echo "$SRC_DIR/config/validator.zig"
            echo "$SRC_DIR/config/tls.zig"
            ;;
        *)
            print_color "$RED" "Unknown batch: $batch"
            echo "Usage: $0 batch[1-6]"
            exit 1
            ;;
    esac
}

# Show detailed info for a specific file
file_info() {
    local file=$1

    if [ ! -f "$file" ]; then
        print_color "$RED" "File not found: $file"
        exit 1
    fi

    print_color "$BLUE" "=== Logging Analysis: $file ==="
    echo ""

    print_color "$YELLOW" "std.debug.print usage:"
    grep -n "std\.debug\.print" "$file" || echo "  None found"
    echo ""

    print_color "$YELLOW" "std.log.* usage:"
    grep -n "std\.log\." "$file" || echo "  None found"
    echo ""

    local total=$(grep "std\.debug\.print\|std\.log\." "$file" | wc -l | tr -d ' ')
    print_color "$GREEN" "Total instances: $total"
}

# Verify migration is complete
verify() {
    print_color "$BLUE" "=== Migration Verification ==="
    echo ""

    local debug_print_count=$(grep -r "std\.debug\.print" "$SRC_DIR" --include="*.zig" --exclude="$EXCLUDE_FILE" | wc -l | tr -d ' ')
    local std_log_count=$(grep -r "std\.log\." "$SRC_DIR" --include="*.zig" | wc -l | tr -d ' ')

    if [ "$debug_print_count" -eq 0 ] && [ "$std_log_count" -eq 0 ]; then
        print_color "$GREEN" "✅ Migration complete!"
        print_color "$GREEN" "   All logging uses util/logging.zig"
        echo ""
        print_color "$YELLOW" "Next steps:"
        echo "  1. Run: zig build test"
        echo "  2. Test with: ./zig-out/bin/zigcat -v localhost 9999"
        echo "  3. Update TODO.md to mark logging consolidation complete"
        return 0
    else
        print_color "$RED" "❌ Migration incomplete"
        echo "   std.debug.print remaining: $debug_print_count"
        echo "   std.log.* remaining:       $std_log_count"
        echo ""

        if [ "$debug_print_count" -gt 0 ]; then
            print_color "$YELLOW" "Files with std.debug.print:"
            grep -r "std\.debug\.print" "$SRC_DIR" --include="*.zig" --exclude="$EXCLUDE_FILE" -l
            echo ""
        fi

        if [ "$std_log_count" -gt 0 ]; then
            print_color "$YELLOW" "Files with std.log.*:"
            grep -r "std\.log\." "$SRC_DIR" --include="*.zig" -l
            echo ""
        fi

        return 1
    fi
}

# Check batch progress
batch_progress() {
    local batch=$1

    print_color "$BLUE" "=== Batch $batch Progress ==="
    echo ""

    local files=$(list_batch "$batch" 2>/dev/null | grep -v "^Batch")
    local total_files=$(echo "$files" | wc -l | tr -d ' ')
    local clean_files=0

    for file in $files; do
        if [ -f "$file" ]; then
            local count=$(grep "std\.debug\.print\|std\.log\." "$file" 2>/dev/null | wc -l | tr -d ' ')
            if [ "$count" -eq 0 ]; then
                clean_files=$((clean_files + 1))
                echo "  ✅ $file"
            else
                echo "  ❌ $file ($count instances)"
            fi
        fi
    done

    echo ""
    print_color "$YELLOW" "Progress: $clean_files/$total_files files migrated"

    local percent=$((clean_files * 100 / total_files))
    if [ "$percent" -eq 100 ]; then
        print_color "$GREEN" "Batch $batch complete!"
    else
        print_color "$YELLOW" "Batch $batch: ${percent}% complete"
    fi
}

# Main command dispatcher
case "${1:-help}" in
    analyze)
        analyze
        ;;
    batch1|batch2|batch3|batch4|batch5|batch6)
        list_batch "${1:5}"
        ;;
    progress1|progress2|progress3|progress4|progress5|progress6)
        batch_progress "${1:8}"
        ;;
    file)
        if [ -z "${2:-}" ]; then
            print_color "$RED" "Usage: $0 file <path>"
            exit 1
        fi
        file_info "$2"
        ;;
    verify)
        verify
        ;;
    help|*)
        print_color "$BLUE" "Logging Migration Helper"
        echo ""
        echo "Usage: $0 <command> [args]"
        echo ""
        echo "Commands:"
        echo "  analyze              - Show current logging usage statistics"
        echo "  batch[1-6]           - List files in migration batch"
        echo "  progress[1-6]        - Show migration progress for batch"
        echo "  file <path>          - Show detailed logging info for file"
        echo "  verify               - Verify migration is complete"
        echo "  help                 - Show this help message"
        echo ""
        echo "Examples:"
        echo "  $0 analyze"
        echo "  $0 batch1"
        echo "  $0 progress2"
        echo "  $0 file src/client.zig"
        echo "  $0 verify"
        ;;
esac
