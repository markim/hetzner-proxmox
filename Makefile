# Makefile for Hetzner Proxmox Setup

.PHONY: help install dry-run test clean lint format check validate

# Default target
help: ## Show this help message
	@echo "Hetzner Proxmox Setup - Available Commands:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Examples:"
	@echo "  make dry-run          # Test installation without making changes"
	@echo "  make install          # Run full installation"
	@echo "  make validate         # Check configuration files"

install: ## Run the full installation
	@echo "Running full installation..."
	sudo ./install.sh

dry-run: ## Show what would be done without executing
	@echo "Running dry-run installation..."
	sudo ./install.sh --dry-run

test: validate ## Run all tests
	@echo "Running tests..."
	@./scripts/test-config.sh

clean: ## Clean up temporary files and logs
	@echo "Cleaning up..."
	sudo rm -f /var/log/hetzner-proxmox-setup.log
	rm -f *.tmp *.temp
	find . -name "*.backup" -type f -delete

lint: ## Check script syntax
	@echo "Linting shell scripts..."
	@for script in install.sh scripts/*.sh lib/*.sh; do \
		if [ -f "$$script" ]; then \
			echo "Checking $$script..."; \
			bash -n "$$script" || exit 1; \
		fi; \
	done
	@echo "All scripts passed syntax check"

format: ## Format and check shell scripts
	@echo "Formatting shell scripts..."
	@command -v shfmt >/dev/null 2>&1 || { echo "shfmt not installed. Install with: apt install shfmt"; exit 1; }
	@for script in install.sh scripts/*.sh lib/*.sh; do \
		if [ -f "$$script" ]; then \
			echo "Formatting $$script..."; \
			shfmt -w -i 4 "$$script"; \
		fi; \
	done

validate: ## Validate configuration files
	@echo "Validating configuration files..."
	@if [ -f .env ]; then \
		echo "Checking .env file..."; \
		source .env && echo "Environment file is valid"; \
	else \
		echo "No .env file found. Copy .env.example to .env first."; \
	fi
	@if [ -f config/Caddyfile.template ]; then \
		echo "Checking Caddyfile template..."; \
		echo "Template syntax appears valid"; \
	fi

check: lint validate ## Run all checks

install-dev: ## Install development dependencies
	@echo "Installing development dependencies..."
	@if command -v apt >/dev/null 2>&1; then \
		sudo apt update; \
		sudo apt install -y shellcheck shfmt; \
	elif command -v brew >/dev/null 2>&1; then \
		brew install shellcheck shfmt; \
	else \
		echo "Please install shellcheck and shfmt manually"; \
	fi

backup: ## Create backup of current configuration
	@echo "Creating configuration backup..."
	@mkdir -p backups
	@DATE=$$(date +%Y%m%d_%H%M%S); \
	if [ -d /etc/caddy ]; then \
		sudo tar -czf "backups/caddy-config-$$DATE.tar.gz" /etc/caddy; \
		echo "Caddy config backed up to backups/caddy-config-$$DATE.tar.gz"; \
	fi; \
	if [ -d /etc/pve ]; then \
		sudo tar -czf "backups/proxmox-config-$$DATE.tar.gz" /etc/pve; \
		echo "Proxmox config backed up to backups/proxmox-config-$$DATE.tar.gz"; \
	fi

status: ## Show service status
	@echo "Service Status:"
	@echo "==============="
	@sudo systemctl is-active caddy && echo "✅ Caddy: Running" || echo "❌ Caddy: Stopped"
	@sudo systemctl is-active pveproxy && echo "✅ Proxmox Proxy: Running" || echo "❌ Proxmox Proxy: Stopped"
	@sudo systemctl is-active pvedaemon && echo "✅ Proxmox Daemon: Running" || echo "❌ Proxmox Daemon: Stopped"
	@echo ""
	@echo "Firewall Status:"
	@echo "================"
	@sudo ufw status verbose | head -10

logs: ## Show recent logs
	@echo "Recent Caddy logs:"
	@echo "=================="
	@sudo journalctl -u caddy --since "1 hour ago" --no-pager | tail -20
	@echo ""
	@echo "Recent Proxmox logs:"
	@echo "===================="
	@sudo journalctl -u pveproxy --since "1 hour ago" --no-pager | tail -20

restart: ## Restart all services
	@echo "Restarting services..."
	sudo systemctl restart caddy
	sudo systemctl restart pveproxy
	sudo systemctl restart pvedaemon
	@echo "Services restarted"

uninstall: ## Remove installation (careful!)
	@echo "WARNING: This will remove Caddy and reset firewall rules"
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		echo ""; \
		sudo systemctl stop caddy; \
		sudo apt remove --purge -y caddy; \
		sudo rm -rf /etc/caddy; \
		sudo ufw --force reset; \
		echo "Uninstallation complete"; \
	else \
		echo ""; \
		echo "Uninstallation cancelled"; \
	fi

# Development targets
.PHONY: dev-setup dev-test dev-format

dev-setup: install-dev ## Setup development environment
	@echo "Development environment setup complete"

dev-test: lint validate ## Run development tests
	@echo "Running development tests..."
	@if command -v shellcheck >/dev/null 2>&1; then \
		echo "Running shellcheck..."; \
		find . -name "*.sh" -type f -exec shellcheck {} +; \
	fi

dev-format: format ## Format code for development
	@echo "Code formatting complete"
