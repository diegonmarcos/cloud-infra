
# Index

> [!abstract]  A) Product Requirements (PRD)
>
> [[#A) Product Requirements (PRD)]] - Product Vision & Personas
> - **[[#A0) Product Vision]] **- Personas, Entry Points, Categories
> 	-  1. Problem Statement     
> 	- 2. Goals & Success Metrics
> 	- 3. User Personas        
>
> - **[[#A1) Product Development]]** - Cloud Portal & CLI Tools
> 	- Web
> 		- [[#B0) Cloud Portal web|B0) Cloud Portal Web]]
> 		  - [[#B00) Summary|B00) Summary]] - Structure overview
> 		  - [[#B01) Detailed|B01) Detailed]] - Full navigation tree
> 		    - **A00_User_Products**: Products (Linktree, AI, Productivity, Media, City Services, Hardware)
> 		    - **A01_User_Services**: Services (Cloud Access, Your Data, Service List, Config)
> 		    - **B00_Dev_Cloud_Control_Center**: Cloud Control Center (Orchestrate, Monitor, Security, Cost)
> 		    - **B01_Dev_Services**: Services (Cloud Control app)
> 		    - **B02_Dev_Code_Wiki**: Code Wiki (Stack, Security, Service, Infra, Data, AI, Ops)
> 	- CLI Apps
> 		- [[#A11) Cloud Connect (Super App)]] - VPN, Vault, Mount, Sync, SSH (User + Dev)
> 		- [[#A12) Cloud Control Center (CLI)]] - Orchestrate, Monitor, Security, Cost (Dev only)
> 	- Core Systems
> 		- [[#A13) Security]] - Authelia, Headscale, YubiKey, Passwordless
> 		- [[#A14) Data Knowledge Center]] - Collectors, Storage, API, MCP Servers
> 		- [[#A15) Others Definitions]] - Web hosting, CI/CD


- A1) Product Development
		- Cloud Portal:
			- User Portal : Cloud Products and Apps 
				- 
			- Dev Portal: Cloud Control Center and WikiCode web and apps
				- C3
					- Monitor
					- Orchestarte
					- 
				- Wiki
					- Product Requirements, Architecture Design and Software Technical Design  
	- Own Your Data --> Data Knowledge Center --> Access it using your own fined tunned AI
		- Collect Raw Data, Clean, Convert to Json
		- Store it in: Vector and Databses
		- Serve it: Online (API and MCP) and Locally () 


---


---

# A) Product Requirements (PRD)

### A0) Product Vision

```
 1. Problem Statement      | Giving data back to the owners  
 2. Goals & Success Metrics| KPIs, OKRs  
 3. User Personas          | Those who have more then 10 accounts created on the web  
 4. User Stories           | As a user, I want have raw access to all my data, so that i could have inteligence data generated
 5. Requirements           | Functional & non-functional  
 6. Scope                  | In scope / out of scope  
 7. Wireframes/Mockups     | Visual reference (optional)  
 8. Dependencies           | External systems, APIs  
 9. Timeline               | Milestones (no estimates)  
 10. Open Questions        | Unresolved decisions
```

```
CLOUD PRODUCT VISION - SUMMARY
══════════════════════════════════════════════════════════════════════════════

PERSONAS
────────────────────────────────────────────────────────────────────────────────
User                           │ End-user accessing products via web/CLI
Dev                            │ DevOps managing infrastructure via C3

ENTRY POINTS
────────────────────────────────────────────────────────────────────────────────
Web Portal                     │ cloud.diegonmarcos.com (User + Dev dashboards)
CLI: Cloud Connect             │ Super App: VPN → Vault → Mount → Sync → SSH
CLI: Cloud Control Center      │ C3: Orchestrate, Monitor, Security, Cost


PRODUCT CATEGORIES (User)
────────────────────────────────────────────────────────────────────────────────


CLOUD CONTROL CENTER (Dev)
────────────────────────────────────────────────────────────────────────────────




```


## A1) Product Development
### A10) Cloud Portal web


[[Cloud_Product_Canvas.canvas]]
![[Cloud_Product_Canvas.canvas]]




#### B00) Summary

``` java
// CLOUD PORTAL FRONT Summary

// A_User
↳ 0_Products                        |: // Office Suite, Media, City Services, My Hardware and AI
↳ 1_Services                        |: //

// B_Dev
↳ 2_Cloud Control Center            |: // Orchestrate, Monitor, Security, Cost
↳ 3_Services                        |: //
↳ 4_Code Wiki                       |: // Stack, Security, Services specs, Infra Docs, Data Knwolodge Center, AI, Ops


/**
* hi
*/

```



``` java
// CLOUD PORTAL FRONT Summary

// A_User
↳ 0_Products
	↳ 00_Linktree                   |: // Professional, Personal
	↳ 01_AI                         |: // YourAI, Multi-Model Orchestration
	↳ 02_Productivity               |: // Mail, Calendar, Suite (Notes, Slides, Sheets, Dashboards)
	↳ 03_Media                      |: // Photos, Music, Videos, Movies, Games
	↳ 04_City Services              |: // Maps, Transport, Gov ID, Banking, Health, Real Estate, Utilities, Markets
	↳ 05_My Hardware                |: // IOT, Wearables, Mobile Hardware, Desk Hardware

↳ 1_Services
	↳ 10_Cloud Access               |: // Cloud Connect, Vault, Sync (Drive, Git), Terminal
	↳ 11_Your Data                  |: // Data Knowledge Center (REST API, MCP, Vector DB)
	> 12_Service List               |: // Active backend services
	> 13_Config Panel               |: // User preferences

// B_Dev
↳ 2_Cloud Control Center
	↳ 20_Orchestrate                |: // Infrastructure, Docker, Stack, Workflows (Temporal, LangGraph)
	↳ 21_Monitor                    |: // Resources (Uptime Kuma), Audit (Dozzle), Analytics (Matomo)
	↳ 22_Security                   |: // Network, Firewall, Backup (Borgmatic), Scans (Trivy)
	↳ 23_Cost                       |: // Infra costs, AI token costs
	↳ 24_Cloud_control.py           |: // Infra costs, AI token costs

↳ 3_Services
	↳ 10_Cloud Control app          |: // cloud_control.py: generates json.js (for local html), md and csv; uses api and also will have porper ssh comands as it would be runing from a admin pc

↳ 4_Code Wiki
	> 40_Stack                      |: // Full Tech stack table
	> 41_Security                   |: // Security architecture
	> 42_Service                    |: // Service specs
	> 43_Infra                      |: // Infrastructure docs
	> 44_Data Knowledge Center      |: // Data flow, API, MCPs, Databases
	> 46_AI                         |: // AI/ML architecture
	> 47_Ops                        |: // Operations runbooks

/**
* Use java markdown
* dont forget that @param is
* @retrun will
*/

```
#### B01) Detailed
``` java
// CLOUD PORTAL FRONT detailed

// A_User
↳ 0_Products

	↳ 00_Linktree
		> Professional			       |: // Work profiles, portfolio
		> Personal				       |: // Personal links

	↳ 01_AI
		> YourAI				       |: // CLI and WebChat: Fine Tuned Personal Agent + Trained No Agent Experts
		> Multi-Model Orch		       |: // CLI and Web: Multi_model_orchestration

	↳ 02_Productivity
		↳ Mail					|: // Mail service login page
			> Mailu				       |: // Webmail, server
			> IMAP,SMTP configs	       |: // copy infos button
		↳ Calendar				|: // CalDAV, CardDAV access
			> Calendar			       |: // calendar web view
			> cal configs		       |: // copy infos button
		↳ Suite
			↳ Notes
				> Notes			       |: // Dev focused slides
				> Clickup
			↳ Slides
				> Slidev			   |: // Dev focused slides
				> Reveal			   |: // Rich presentations
			↳ Sheets
				> Pandas			   |: // Data processing
				> XSV				   |: // Fast CSV operations
			↳ Dashboards
				> Jupyter			   |: // Interactive notebooks
				> Dash				   |: // Python dashboards

	↳ 03_Media
		↳ Photos				    |: // Photo gallery login
            > Photoprism		       |: // Photoprism login
            > Immich			       |: // Immich login
            > Pinterest                |: //
		↳ Music				        |: // Music gallery  
			> Spotify
			> MyMusic                  |: //
		↳ Videos				    |: // Videos gallery 
			> Youtube
			> MyVideos                 |: //
		↳ Movies				    |: // Movies gallery 
			> Stream Plataforms        |: // Netlfix...
			> MyMovies                 |: //

		↳ Games  				    |: // Games gallery 
			> Steam                    |: // 

     ↳ 04_City Services
		↳ Maps				        |: //
			> MyMaps                 |: //
			> Maps.me
			> Google Maps
		↳ Transport				    |: //				
				
		↳ Gov ID				    |: //
		↳ Banking				    |: //
		↳ Health				    |: //

		↳ Real Estate				|: //				
		↳ Utilities				    |: //				

		↳ Markets				    |: //		

     ↳ 05_My Hardware               |: // Hardware Inventory Asset listing and each specs tables
		↳ IOT
		   > SmartTag_Card
		↳ Werables
		   > Ring
		   > Smatwatch_GarminOS
		   > EarBuds_Samsung
		   > Glass_Vision
		↳ Mobile Hardware
           > Yubikey_5_nfc_rsa    	     
	       > Phone_AndroidOS 
	       > Tablet_AndroidOS
		↳ Desk Hardware
	       > Noteboko2in1_FedoraOS_WinOS_FydeOS
		
↳ 1_Services (User)
	↳ 10_Cloud Access                  |: // 
		> Cloud Connect			       |: // Super App: cloud_connect.py (login:VPN_"rsa")
		> Vault					       |: // Bitwarden extension, Vaultwarden link
		↳ Sync					    |:  // Login Page
			> Drive				       |: // Cloud storage mount
			> Git				       |: // Git hosting (Gitea)
		↳ Terminal
		   > VSCode SSH			       |: // SSH config  remote dev
		   > More...		           |: // Future: cloud-cli, ai-cli	
	↳ 11_Your Data   				|: // Your Data = Data Knowledge Center
		> FastAPIDocs                  |: // REST API, MCP Servers, Vector DB, Central DB
	> 12_Service List				   |: // Active backend services: proxy, auth, vpn...
	> 13_Config Panel				   |: // User preferences


// B_Dev
↳ 2_Cloud Control Center
	↳ 20_Orchestrate
		> Infrastructure		|: // VMs, IPs, topology
		> Docker				|: // Container management:  Dockge
		> Stack					|: // Service consolidation
		↳ Workflows
			> Temporal			|: // Infra workflows
			> LangGraph			|: // AI agent workflows
	↳ 21_Monitor
		> Resources				|: // CPU, RAM, disk usage and Healthy (Uptime Kuma 
		> Audit					|: // Logs : Dozzle / Portainer
		> Analytics				|: // Web stats: Matomo
	↳ 22_Security
		> Network				|: // Docker network segmentation
		> Firewall				|: // Ports, rules per vm
		> Backup				|: // Borgmatic backups
		> Scans					|: // Trivy vulnerability scans
	↳ 23_Cost
		> Infra					|: // Cloud provider costs
		> AI					|: // Token usage costs

↳ 3_Services (Dev)
	↳ 10_Cloud Control app          |: // cloud_control.py: generates json.js (for local html), md and csv; uses api and also 

↳ 4_Code Wiki                   |: // Always-current Architecture and sequence diagrams
	> 40_Stack						|: // Full Tech stack table
	> 41_Security					|: // Security architecture
	> 42_Service					|: // Service specs
	> 43_Infra						|: // Infrastructure docs
	> 44_Data Knowledge Center		|: // Data flow docs, API, MCPs, Databases(Vectors, OLTP, OLAP), Scripts
	> 46_AI						    |: // AI/ML architecture
	> 47_Ops						|: // Operations runbooks
	

/**
* Use java markdown
* dont forget that @param is
* @retrun will
*/

```

### A11) Cloud Connect (Super App)

> **Vision**: A single CLI that unifies all cloud access. Login once to VPN → automatically unlock Vault, mount drives, sync files, and access all services. One command to rule them all.

---

#### 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           CLOUD CONNECT                                     │
│                         (Super App CLI)                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│                          ┌─────────────┐                                    │
│                          │   LOGIN     │                                    │
│                          │ (VPN Auth)  │                                    │
│                          └──────┬──────┘                                    │
│                                 │                                           │
│                    ┌────────────┼────────────┐                              │
│                    ▼            ▼            ▼                              │
│             ┌───────────┐ ┌───────────┐ ┌───────────┐                       │
│             │   VAULT   │ │   SYNC    │ │  ACCESS   │                       │
│             │(Passwords)│ │ (Drives)  │ │(Services) │                       │
│             └───────────┘ └───────────┘ └───────────┘                       │
│                    │            │            │                              │
│         ┌──────────┴──────────┬─┴────────────┴──────────┐                   │
│         ▼                     ▼                         ▼                   │
│  ┌─────────────┐       ┌─────────────┐          ┌─────────────┐             │
│  │ Vaultwarden │       │   rclone    │          │     SSH     │             │
│  │ (Bitwarden) │       │  Syncthing  │          │   Gitea     │             │
│  └─────────────┘       └─────────────┘          └─────────────┘             │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                          STATUS DASHBOARD                                   │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐   │
│  │VPN: ✅  │ │Vault:✅ │ │Mount:✅ │ │Sync: ✅ │ │SSH: ✅  │ │Git: ✅  │   │
│  └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

#### 2. User Personas & Features

| Feature          | User (Web Access)      | Dev (Terminal Access)           |
| ---------------- | ---------------------- | ------------------------------- |
| **VPN**          | ✅ Connect/Disconnect  | ✅ Connect/Disconnect           |
| **Vault**        | ✅ Browser extension   | ✅ CLI access + browser         |
| **Mount**        | ❌                     | ✅ rclone FUSE (all drives)     |
| **Sync**         | ✅ Syncthing (basic)   | ✅ Syncthing + BiSync           |
| **SSH**          | ❌                     | ✅ All VMs (via VPN mesh)       |
| **Git**          | ❌                     | ✅ Gitea clone/pull/push        |
| **Dashboard**    | ✅ Status view         | ✅ Full monitoring              |

---

#### 3. Core Modules

| Module           | Tech Stack             | Responsibility                              |
| ---------------- | ---------------------- | ------------------------------------------- |
| **VPN Manager**  | WireGuard + Headscale  | Tunnel connection, key management           |
| **Vault Access** | Vaultwarden API        | Credential retrieval, browser integration   |
| **Mount Engine** | rclone FUSE            | Cloud drives as local directories           |
| **Sync Daemon**  | Syncthing + BiSync     | Real-time bidirectional file sync           |
| **SSH Manager**  | OpenSSH + config       | VM access, host management                  |
| **Git Bridge**   | Gitea API + Git CLI    | Repository operations                       |
| **Dashboard**    | Rich/Textual TUI       | Live status monitoring                      |

---

#### 4. CLI Interface

```bash
# Quick Commands
cloud-connect                    # Launch TUI (interactive mode)
cloud-connect --status           # Show dashboard (non-interactive)
cloud-connect --connect          # VPN + Vault + Mount + Sync (one shot)
cloud-connect --disconnect       # Unmount + Stop sync + VPN off

# Module Commands
cloud-connect vpn [on|off|status]
cloud-connect vault [login|status|lock]
cloud-connect mount [all|unmount|list]
cloud-connect sync [start|stop|status]
cloud-connect ssh [vm-name]
cloud-connect git [clone|pull|status] [repo]

# Setup (first run)
cloud-connect setup              # Interactive setup wizard
cloud-connect setup vpn          # Configure WireGuard keys
cloud-connect setup vault        # Link Vaultwarden account
cloud-connect setup mount        # Configure rclone remotes
cloud-connect setup sync         # Configure Syncthing folders
```

---

#### 5. Connection Flow

| Step | Action                        | Module        | Auto-Triggered         |
| ---- | ----------------------------- | ------------- | ---------------------- |
| 1    | User runs `cloud-connect`     | CLI           | —                      |
| 2    | Authenticate to VPN           | VPN Manager   | —                      |
| 3    | Unlock Vault                  | Vault Access  | ✅ After VPN connected |
| 4    | Mount cloud drives            | Mount Engine  | ✅ After VPN connected |
| 5    | Start file sync               | Sync Daemon   | ✅ After mounts ready  |
| 6    | Display dashboard             | Dashboard     | ✅ Always              |

---

#### 6. Status Dashboard

```
┌─────────────────────────────────────────────────────────────────┐
│                    CLOUD CONNECT STATUS                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  NETWORK                           SERVICES                     │
│  ─────────────────────────         ─────────────────────────    │
│  VPN:      ✅ Connected            Vault:    ✅ Unlocked        │
│  Tunnel:   mesh (private)          Session:  23h remaining      │
│  Latency:  12ms                                                 │
│                                                                 │
│  STORAGE                           SYNC                         │
│  ─────────────────────────         ─────────────────────────    │
│  ~/cloud/drive    ✅ mounted       Documents  ✅ synced         │
│  ~/cloud/photos   ✅ mounted       Projects   ✅ synced         │
│  ~/cloud/backup   ✅ mounted       Media      ⏳ syncing (42%)  │
│                                                                 │
│  VMs (Dev Only)                    GIT REPOS                    │
│  ─────────────────────────         ─────────────────────────    │
│  oracle-web-1     ✅ reachable     front-Github_io  ✅ clean    │
│  oracle-svc-1     ✅ reachable     back-System      ⚠️  3 ahead │
│  gcloud-arch-1    ✅ reachable     ml-Agentic       ✅ clean    │
│                                                                 │
│  [Q]uit  [R]efresh  [V]PN  [M]ount  [S]ync  [SSH]  [G]it       │
└─────────────────────────────────────────────────────────────────┘
```

---

#### 7. Project Structure

```
/cloud-connect
│
├── main.py                      # Entry point + CLI parser
├── config.py                    # User config, paths, remotes
│
├── /core                        # Core modules
│   ├── vpn.py                   # WireGuard/Headscale management
│   ├── vault.py                 # Vaultwarden API client
│   ├── mount.py                 # rclone FUSE operations
│   ├── sync.py                  # Syncthing + BiSync control
│   ├── ssh.py                   # SSH config & connections
│   └── git.py                   # Gitea integration
│
├── /ui                          # User interface
│   ├── tui.py                   # Rich/Textual TUI
│   ├── dashboard.py             # Status dashboard widget
│   └── prompts.py               # Interactive prompts
│
├── /setup                       # First-run setup
│   ├── wizard.py                # Setup wizard
│   ├── vpn_setup.py             # WireGuard key generation
│   ├── vault_setup.py           # Vaultwarden account linking
│   ├── mount_setup.py           # rclone remote config
│   └── sync_setup.py            # Syncthing folder config
│
└── /utils                       # Utilities
    ├── network.py               # Ping, connectivity checks
    ├── process.py               # Daemon management
    └── keyring.py               # Secure credential storage
```

---

#### 8. Design Principles

1. **One Login, Full Access**: VPN authentication unlocks everything automatically
2. **Dual Persona**: Same app works for Users (simple) and Devs (full features)
3. **Always-On Dashboard**: Real-time status visibility at a glance
4. **Graceful Degradation**: Individual module failures don't break the whole app
5. **Offline Capable**: Cached credentials, local-first file access
6. **Setup Once**: First-run wizard, then zero-config daily use

---

---

### A12) Cloud Control Center (CLI)

> **Vision**: The command-line interface to the Cloud Control Center. Everything the web dashboard does via API, the Dev can do via CLI. Full infrastructure visibility and control from the terminal.

---

#### 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      CLOUD CONTROL CENTER (CLI)                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                         TUI / CLI INTERFACE                         │   │
│   │   cloud-control [orchestrate|monitor|security|cost] [subcommand]    │   │
│   └─────────────────────────────────┬───────────────────────────────────┘   │
│                                     │                                       │
│         ┌───────────────────────────┼───────────────────────────┐           │
│         ▼                           ▼                           ▼           │
│  ┌─────────────┐           ┌─────────────────┐          ┌─────────────┐     │
│  │ ORCHESTRATE │           │    MONITOR      │          │  SECURITY   │     │
│  │ (Infra)     │           │ (Observability) │          │  (Protect)  │     │
│  └─────────────┘           └─────────────────┘          └─────────────┘     │
│         │                           │                           │           │
│         ▼                           ▼                           ▼           │
│  ┌─────────────┐           ┌─────────────────┐          ┌─────────────┐     │
│  │    COST     │           │     EXPORT      │          │     API     │     │
│  │  (Budget)   │           │ (json/md/csv)   │          │  (FastAPI)  │     │
│  └─────────────┘           └─────────────────┘          └─────────────┘     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

#### 2. Module Overview

| Module         | Purpose                              | Data Sources                        |
| -------------- | ------------------------------------ | ----------------------------------- |
| **Orchestrate**| Infrastructure & container control   | OCI, GCloud, Docker APIs            |
| **Monitor**    | Health, performance, analytics       | Uptime Kuma, Dozzle, Matomo         |
| **Security**   | Backup, scans, network               | Borgmatic, Trivy, Firewall          |
| **Cost**       | Budget tracking                      | Cloud billing, AI token usage       |
| **Export**     | Data output formats                  | All modules → JSON, MD, CSV, JS     |

---

#### 3. CLI Interface

```bash
# Launch TUI
cloud-control                        # Interactive dashboard

# Orchestrate Commands
cloud-control orchestrate infra      # Show VMs, IPs, topology
cloud-control orchestrate docker     # Container status (like Dockge)
cloud-control orchestrate stack      # Service consolidation view
cloud-control orchestrate workflows  # Temporal + LangGraph status

# Monitor Commands
cloud-control monitor health         # Uptime Kuma status
cloud-control monitor logs [svc]     # Dozzle-style log view
cloud-control monitor perf           # CPU, RAM, disk metrics
cloud-control monitor analytics      # Matomo stats export

# Security Commands
cloud-control security backup        # Borgmatic status, trigger backup
cloud-control security scan          # Trivy vulnerability report
cloud-control security network       # Docker network segmentation
cloud-control security firewall      # Port rules per VM

# Cost Commands
cloud-control cost infra             # Cloud provider billing
cloud-control cost ai                # AI token usage breakdown
cloud-control cost report            # Combined cost report

# Export Commands
cloud-control export json            # Export all data as JSON
cloud-control export md              # Export as Markdown tables
cloud-control export csv             # Export as CSV files
cloud-control export js              # Export as JS for web dashboard
```

---

#### 4. Core Components

| Component           | Tech Stack          | Responsibility                               |
| ------------------- | ------------------- | -------------------------------------------- |
| **Infra Scanner**   | OCI + GCloud SDK    | VM inventory, IP topology                    |
| **Docker Client**   | Docker SDK          | Container status, logs, restart              |
| **Workflow Engine** | Temporal + LangGraph| Workflow status, triggers                    |
| **Health Checker**  | Uptime Kuma API     | Service availability                         |
| **Log Aggregator**  | Dozzle API          | Centralized log viewing                      |
| **Analytics Client**| Matomo API          | Web traffic stats                            |
| **Backup Manager**  | Borgmatic CLI       | Backup status, trigger, restore              |
| **Vuln Scanner**    | Trivy CLI           | Container vulnerability reports              |
| **Cost Calculator** | Billing APIs        | Cloud + AI cost aggregation                  |
| **Exporter**        | Python (Pandas)     | Multi-format data export                     |

---

#### 5. TUI Dashboard

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      CLOUD CONTROL CENTER                                   │
├──────────────────────────────┬──────────────────────────────────────────────┤
│  INFRASTRUCTURE              │  SERVICES                                    │
│  ────────────────────────    │  ────────────────────────────────────────    │
│  VMs:         3 running      │  Containers:    12 running / 2 stopped       │
│  IPs:         3 public       │  Healthy:       11 ✅  / 1 ⚠️  / 2 ❌        │
│  Networks:    5 configured   │                                              │
│                              │  RECENT LOGS                                 │
│  COSTS (This Month)          │  ────────────────────────────────────────    │
│  ────────────────────────    │  [npm]     TLS renewed for *.domain.com     │
│  Oracle:      $0.00          │  [matomo]  Archived 2024-01 reports         │
│  Google:      $12.34         │  [sync]    Sync completed successfully      │
│  AI Tokens:   $8.56          │  [backup]  Daily backup successful          │
│  ─────────────               │                                              │
│  Total:       $20.90         │  ALERTS                                      │
│                              │  ────────────────────────────────────────    │
│  SECURITY                    │  ⚠️  Certificate expires in 14 days         │
│  ────────────────────────    │  ⚠️  Disk usage 85% on oracle-web-1         │
│  Last Backup: 2h ago ✅      │                                              │
│  Vuln Scan:   3 low, 0 high  │                                              │
│  Firewall:    All rules OK   │                                              │
│                              │                                              │
├──────────────────────────────┴──────────────────────────────────────────────┤
│  [O]rchestrate  [M]onitor  [S]ecurity  [C]ost  [E]xport  [Q]uit            │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

#### 6. Export Formats

| Format   | File              | Purpose                                    |
| -------- | ----------------- | ------------------------------------------ |
| **JSON** | `cloud_data.json` | Machine-readable, API consumption          |
| **JS**   | `cloud_data.js`   | Web dashboard (embedded in HTML)           |
| **MD**   | `cloud_report.md` | Human-readable documentation               |
| **CSV**  | `cloud_*.csv`     | Spreadsheet analysis, cost tracking        |

---

#### 7. Project Structure

```
/cloud-control-center
│
├── main.py                      # Entry point + CLI parser
├── config.py                    # API endpoints, credentials paths
│
├── /orchestrate                 # Infrastructure management
│   ├── architecture.py          # VM inventory, topology
│   ├── docker.py                # Container operations
│   ├── stack.py                 # Service consolidation
│   └── workflows.py             # Temporal + LangGraph
│
├── /monitor                     # Observability
│   ├── availability.py          # Uptime Kuma integration
│   ├── performance.py           # Resource metrics
│   ├── logs.py                  # Dozzle log aggregation
│   └── analytics.py             # Matomo stats
│
├── /security                    # Protection
│   ├── backups.py               # Borgmatic operations
│   ├── scans.py                 # Trivy vulnerability reports
│   ├── network.py               # Docker network audit
│   └── firewall.py              # Port/rule management
│
├── /cost                        # Budget tracking
│   ├── infra.py                 # Cloud billing (OCI, GCloud)
│   └── ai.py                    # Token usage (Claude, OpenAI)
│
├── /export                      # Data output
│   ├── to_json.py               # JSON exporter
│   ├── to_js.py                 # JS exporter (for web)
│   ├── to_md.py                 # Markdown exporter
│   └── to_csv.py                # CSV exporter
│
├── /ui                          # User interface
│   ├── tui.py                   # Rich/Textual TUI
│   ├── dashboard.py             # Main dashboard widget
│   └── tables.py                # Data table renderers
│
└── /api                         # Optional API server
    └── server.py                # FastAPI for web dashboard
```

---

#### 8. Relationship with Cloud Connect

```
┌────────────────────────────────────────────────────────────────────────────┐
│                           CLI TOOL ECOSYSTEM                               │
├────────────────────────────────────────────────────────────────────────────┤
│                                                                            │
│   ┌──────────────────────────┐      ┌──────────────────────────┐           │
│   │     CLOUD CONNECT        │      │   CLOUD CONTROL CENTER   │           │
│   │     (Super App)          │      │        (C3 CLI)          │           │
│   ├──────────────────────────┤      ├──────────────────────────┤           │
│   │ • VPN Connection         │      │ • Infrastructure         │           │
│   │ • Vault Access           │      │ • Monitoring             │           │
│   │ • Drive Mounting         │      │ • Security               │           │
│   │ • File Sync              │      │ • Cost Tracking          │           │
│   │ • SSH Access             │      │ • Exports                │           │
│   ├──────────────────────────┤      ├──────────────────────────┤           │
│   │ WHO: User + Dev          │      │ WHO: Dev Only            │           │
│   │ WHEN: Daily access       │      │ WHEN: Admin tasks        │           │
│   └──────────────────────────┘      └──────────────────────────┘           │
│              │                                   │                         │
│              │         ┌─────────────┐           │                         │
│              └────────►│   SHARED    │◄──────────┘                         │
│                        │   CONFIG    │                                     │
│                        │ (LOCAL_KEYS)│                                     │
│                        └─────────────┘                                     │
│                                                                            │
└────────────────────────────────────────────────────────────────────────────┘
```

---

#### 9. Design Principles

1. **CLI-First**: Full functionality from terminal, no browser required
2. **API Parity**: Everything the web dashboard does, CLI can do
3. **Multi-Format Export**: JSON for machines, MD for humans, JS for web
4. **Modular Architecture**: Each domain (orchestrate/monitor/security/cost) independent
5. **Real-Time TUI**: Live dashboard updates, not just static output
6. **Composable Commands**: Unix philosophy - pipe outputs, chain commands

---

---

### A13) Security

> **Vision**: A passwordless, zero-trust security architecture where authentication is hardware-backed (YubiKey), network access is encrypted (WireGuard), and all services are self-hosted for full control.

---

#### 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          SECURITY ARCHITECTURE                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│                              INTERNET                                       │
│                                  │                                          │
│                                  ▼                                          │
│                    ┌─────────────────────────┐                              │
│                    │      REVERSE PROXY      │                              │
│                    │    (Nginx Proxy Mgr)    │                              │
│                    └───────────┬─────────────┘                              │
│                                │                                            │
│              ┌─────────────────┼─────────────────┐                          │
│              ▼                 ▼                 ▼                          │
│      ┌─────────────┐   ┌─────────────┐   ┌─────────────┐                    │
│      │   PUBLIC    │   │  PROTECTED  │   │   PRIVATE   │                    │
│      │  (websites) │   │  (Authelia) │   │    (VPN)    │                    │
│      └─────────────┘   └──────┬──────┘   └──────┬──────┘                    │
│                               │                 │                           │
│                               ▼                 ▼                           │
│                    ┌──────────────────────────────────┐                     │
│                    │         AUTHENTICATION           │                     │
│                    │  ┌──────────┐    ┌────────────┐  │                     │
│                    │  │ Authelia │◄──►│ Headscale  │  │                     │
│                    │  │ (WebAuth)│OIDC│ (VPN Mesh) │  │                     │
│                    │  └────┬─────┘    └─────┬──────┘  │                     │
│                    │       │                │         │                     │
│                    └───────┼────────────────┼─────────┘                     │
│                            │                │                               │
└────────────────────────────┼────────────────┼───────────────────────────────┘
                             │                │
                        ┌────┴────┐      ┌────┴────┐
                        │ YubiKey │      │ Devices │
                        │ (FIDO2) │      │ (phone, │
                        └─────────┘      │ laptop) │
                                         └─────────┘
```

---

#### 2. Core Components

| Component        | Tech Stack           | Role                                           | Self-Hosted |
| ---------------- | -------------------- | ---------------------------------------------- | ----------- |
| **Reverse Proxy**| Nginx Proxy Manager  | TLS termination, routing, rate limiting        | ✅          |
| **Auth Gateway** | Authelia             | 2FA, WebAuthn/Passkey, session management      | ✅          |
| **VPN Mesh**     | Headscale + WireGuard| Encrypted tunnel, device coordination          | ✅          |
| **Identity**     | OIDC (via Authelia)  | Single sign-on across services                 | ✅          |
| **Hardware Key** | YubiKey 5 NFC        | FIDO2/WebAuthn, passwordless authentication    | N/A         |
| **Secrets Vault**| Vaultwarden          | Password manager, TOTP backup                  | ✅          |

---

#### 3. Authentication Flow

| Step | Action                          | Component        | Protocol       |
| ---- | ------------------------------- | ---------------- | -------------- |
| 1    | User accesses protected service | Nginx Proxy      | HTTPS          |
| 2    | Redirect to auth portal         | Authelia         | HTTP 302       |
| 3    | User taps YubiKey               | Browser + Key    | WebAuthn/FIDO2 |
| 4    | Session token issued            | Authelia         | JWT/Cookie     |
| 5    | Access granted                  | Nginx Proxy      | Forward Auth   |

---

#### 4. Network Exposure

| Service              | Public | Port(s)        | Reason                              |
| -------------------- | ------ | -------------- | ----------------------------------- |
| Websites (static)    | ✅ Yes | 443            | Public content                      |
| Web Apps (protected) | ✅ Yes | 443            | Behind Authelia                     |
| Mail Server          | ✅ Yes | 25, 465, 993   | SMTP/IMAP require public access     |
| SSH                  | ❌ No  | 22             | VPN-only access                     |
| Admin Panels         | ❌ No  | Various        | VPN-only access                     |
| Databases            | ❌ No  | 5432, 3306     | Internal only                       |

---

#### 5. Security Stack

| Layer              | Technology           | Purpose                                    |
| ------------------ | -------------------- | ------------------------------------------ |
| **Edge**           | Cloudflare           | DDoS protection, DNS, WAF                  |
| **Proxy**          | Nginx Proxy Manager  | TLS, routing, access control               |
| **Auth**           | Authelia             | MFA, session, access policies              |
| **Network**        | Headscale/WireGuard  | Encrypted mesh VPN                         |
| **Container**      | Docker networks      | Service isolation                          |
| **Secrets**        | Vaultwarden          | Credential storage                         |
| **Backup**         | Borgmatic            | Encrypted offsite backups                  |
| **Scanning**       | Trivy                | Container vulnerability scanning           |

---

#### 6. Access Policies

| User Type    | Authentication Method     | Access Level                    |
| ------------ | ------------------------- | ------------------------------- |
| **Public**   | None                      | Static websites only            |
| **User**     | Passkey (YubiKey)         | Protected apps via Authelia     |
| **Dev**      | Passkey + VPN             | Admin panels, SSH, databases    |
| **Automated**| API Token + mTLS          | CI/CD, scheduled jobs           |

---

#### 7. Design Principles

1. **Zero Trust**: Every request authenticated, no implicit trust
2. **Passwordless**: Hardware keys (FIDO2) as primary authentication
3. **Self-Hosted**: Full control over authentication and secrets
4. **Defense in Depth**: Multiple security layers (edge → proxy → auth → network)
5. **Least Privilege**: Minimal access by default, explicit grants required
6. **Encrypted Always**: TLS for web, WireGuard for network, encrypted backups

---


### A14) Data Knowledge Center

> **Vision**: A unified execution engine that gives users raw access to their data, enabling intelligence generation through both human interfaces (REST API) and AI agents (MCP).

---

#### 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        DATA KNOWLEDGE CENTER                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌─────────────┐      ┌─────────────┐      ┌─────────────────────────┐     │
│   │  COLLECTORS │ ───► │  CONVERTERS │ ───► │        STORAGE          │     │
│   │  (Ingest)   │      │ (Transform) │      │   (Vector + Relational) │     │
│   └─────────────┘      └─────────────┘      └───────────┬─────────────┘     │
│                                                         │                   │
│                                                         ▼                   │
│                              ┌───────────────────────────────────────┐      │
│                              │           ACCESS GATEWAY              │      │
│                              │      FastAPI (REST + SSE + MCP)       │      │
│                              └───────────┬───────────┬───────────────┘      │
│                                          │           │                      │
│                           ┌──────────────┘           └──────────────┐       │
│                           ▼                                         ▼       │
│                    ┌─────────────┐                           ┌─────────────┐│
│                    │   HUMANS    │                           │  AI AGENTS  ││
│                    │  (REST API) │                           │    (MCP)    ││
│                    └─────────────┘                           └─────────────┘│
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

#### 2. Core Components

| Component          | Tech Stack             | Role                                                    |
| ------------------ | ---------------------- | ------------------------------------------------------- |
| **Logic Core**     | Python (Pandas/Numpy)  | Pure deterministic processing engine                    |
| **Tool Registry**  | Python Dictionary / DB | Security whitelist of executable scripts                |
| **Data Vault**     | ChromaDB + PostgreSQL  | Vector embeddings + structured user data                |
| **Dispatcher**     | Python Function        | Routing, logging, audit trail                           |
| **Access Gateway** | FastAPI (REST + SSE)   | Unified interface for humans and AI agents              |

---

#### 3. Data Pipeline

| Stage         | Input                  | Output              | Tech                    |
| ------------- | ---------------------- | ------------------- | ----------------------- |
| **Collect**   | Public APIs, Local DBs | Raw data            | Python, IMAP, REST      |
| **Convert**   | Raw data               | JSON, MD, CSV       | Pandas, custom scripts  |
| **Store**     | Processed data         | Indexed records     | PostgreSQL, ChromaDB    |
| **Serve**     | Query                  | Response            | FastAPI, MCP            |

---

#### 4. MCP Server Specification

**RESOURCES (read)** - AI knowledge & context retrieval

| Resource             | Purpose              | Stack               | Description                              |
| -------------------- | -------------------- | ------------------- | ---------------------------------------- |
| `masterplan-rag`     | Knowledge Retrieval  | ChromaDB + sentence | Semantic search across masterplans       |
| `file-navigator`     | Codebase Navigation  | Python3 + pathlib   | Find files across 18+ projects           |
| `git-integration`    | History Query        | GitPython           | Commits, blame, file evolution           |
| `secrets-manager`    | Credential Paths     | Python3             | Safe paths to LOCAL_KEYS (never contents)|
| `project-config`     | Metadata Query       | Python3             | package.json, dependencies               |
| `emails`             | Mail Archive         | ChromaDB + IMAP     | Subject, body, attachments               |
| `photos`             | Photo Metadata       | ChromaDB + API      | Tags, captions, metadata                 |
| `monitoring`         | Health & Costs       | Python3             | Uptime, resource usage, alerts           |

**TOOLS (act)** - AI actions & command execution

| Tool                 | Purpose              | Stack               | Description                              |
| -------------------- | -------------------- | ------------------- | ---------------------------------------- |
| `cloud-cli`          | Cloud Commands       | gcloud + oci CLI    | VM status, start, stop                   |
| `docker-manager`     | Service Control      | Docker SDK          | Container logs, restart, health          |
| `build-orchestrator` | Build Automation     | Shell + Python3     | Trigger builds across 18 projects        |
| `github-integration` | GitHub API           | PyGithub            | PR status, workflow runs, triggers       |

---

#### 5. Project Structure

```
/data-knowledge-center
│
├── main.py                      # Entry point
├── config.py                    # Environment & DB paths
│
├── /collectors                  # [INGEST] Data collection
│   ├── public_apis.py           # External API fetchers
│   ├── local_servers.py         # Internal service polling
│   └── scheduled_jobs.py        # Cron-based collection
│
├── /converters                  # [TRANSFORM] Data processing
│   ├── db_to_json.py            # Database exports
│   ├── json_to_md.py            # Markdown generation
│   └── json_to_csv.py           # CSV exports
│
├── /core                        # [LOGIC] Central engine
│   ├── registry.py              # Tool whitelist
│   ├── dispatcher.py            # Universal executor
│   ├── /database
│   │   ├── vector_store.py      # ChromaDB client
│   │   └── sql_db.py            # PostgreSQL client
│   └── /tools
│       ├── search.py            # Vector search logic
│       ├── scraper.py           # External data fetch
│       └── analysis.py          # Pandas processing
│
└── /interfaces                  # [SERVE] Access layer
    ├── api_routes.py            # REST API (FastAPI)
    └── mcp_server.py            # MCP Server
```

---

#### 6. Design Principles

1. **Separation of Concerns**: Logic (data/tools) isolated from interfaces (API/MCP)
2. **Dual Access**: Same data accessible by humans (REST) and AI (MCP)
3. **Security First**: Tool whitelist, audit logging, no credential exposure
4. **Extensibility**: Add new collectors/tools without modifying core

---






### A15) Others Definitions

```
// 
 
- web hosting?
- CLI/CD ?
- ? 
    
```
