## A0000) First Definitions


### CLOUD PORTAL FRONT

```
cloud-portal (simplified)

Portal  
 ├── User ──────────────────────────────────────────── End-user persona  
 │   ├── Products                                        What they use  
 │   │   ├── Terminal (VPN, VSCode)                      
 │   │   ├── Productivity (Mail, Calendar, Photos)  
 │   │   ├── Linktree (Professional/Personal)  
 │   │   └── AI (MCPs, YourAI, MultiModelOrch)  
 │   └── Services                                        Service-level access  
 │       ├── Config Panel                                  User Configs  
 │       └── Service List                                  Back-end Services Actives  
 │  
 └── Dev ───────────────────────────────────────────── DevOps persona  
     ├── Cloud Control Center                            Operations  
     │   ├── Orchestrate (Infra, Docker, Stack)  
     │   ├── Monitor (Resources, Audit)  
     │   ├── Cost (Infra, AI)  
     │   └── Security (Network, Firewall, Layers)  
     └── Architecture                                    Reference Spec docs  
         └── Security/Service/Infra/Data/MCPs/AI/Ops

---

cloud-portal (web)

User	
↳ Products
	  ↳ Cloud Access                   | 
		  ↳ Access                     | cloud_connect.py: copy buttom for curl, click to download , link git repo
		  ↳ Vault                      | Bitwarden browser extension link to connect locally(vpm) Vaultwarden(self hosted)
	  ↳ Terminal
		  ↳ VSCode SSH                 | app.py config and a copy buttom infos for VS code to SHH
		  ↳ More...                    | future devs(cloud-cli-chat and ai-cli-chat)
	  ↳ Productivity
		  ↳ Mail                       | Login page and config infos
		  ↳ Calendar                   | Login page and copy infos
		  ↳ Photos                     | Login page
		  ↳ More...                    | future devs: slides, sheets, dashs, 
	  ↳ Linktree 
		  ↳ Professional
			  ↳ Profiles
			  ↳ Portfolio
			  ↳ Ventures
		  ↳ Personal
			  ↳ Profiles
			  ↳ Portfolio
			  ↳ Ventures
	  ↳ AI
		  ↳ MCPs
		  ↳ YourAI
		  ↳ Multi-Model Orch
	
↳ Services
		↳ Config Panel
		↳ List of Services
			↳ api, dns, proxy, auth...


Dev
↳ Cloud Control Center
    ↳ Orchestrate
	    ↳ Infrastrutucre Full (URLSs/IP:Port/Docker | Topology)
		    ↳ api, dns, proxy, auth, products, ...
	    ↳ Docker Containers
	    ↳ Stack Consolidation
    ↳ Monitor
	    ↳ Resources (Overhead)
	    ↳ Audit (logs)
	↳ Security
	    ↳ Docker Network Segm
	    ↳ Firewall ports and Docker Compose
	    ↳ Security Layers and Services
	↳ Cost
	    ↳ Infra
	    ↳ AI
    
 ↳ Architecture
	  ↳ Stack Consolidation
	  ↳ Security
	  ↳ Service
	  ↳ Infra
	  ↳ Data
	  ↳ MCPs
	  ↳ AI
	  ↳ Ops and Monitor
```


### CLOUD PORTAL BACK-END
```
# cloud-access (terminal)

## cloud_connect.py           | cli

### front
  ↳ Helper                 | -h or --help or invalid arg opens it
	  ↳ run Monitor
	  ↳ Syntax Explanation | Brief, list cli options, examples)

  ↳ TUI (User Actions)
	  0. Monitor
	     ↳ Show Monitor
	  
	  1. User (Web Access)
	  ↳ VPN Connection         | Vpn On/off ;
	  ↳ Vault                  | check if installed and logged in or will make the login
	  
	  2. Dev (Term Access)
	  ↳ SSHs Hosts             | choose a DNS or a Host to access
	  ↳ VPN Connection         | Vpn On/off ;
	  ↳ SSH VMSs               | choose a VM to access
	  ↳ Mount                  | Mount All, Umount All, Mount Checked, Umount Checked; Mode: Private(Slow mesh) or Public IPs (fast)

	  ↳ Vault                  | 
	  
	  3. Setup
	  ↳ SSHs                   | 
	  ↳ VPN Connection         | 
	  ↳ Driver Mnt             | 

### Back-end
	↳ Monitor                                                  | -m or --monitor or hotkey in TUI
	  ↳ Topology (pub/priv ip...)
	  ↳ VPN Status (tunnel mode | local keys, pub key,...), 
	  ↳ VMs Status (ping pub/priv), 
	  ↳ Mount Status (list local mnts), 
	  ↳ Vault Check (browser/extensions installed)
	↳ SSHs                                                   | rsa local -> 
		↳ DNS(Cloudfare, square space), 
		↳ Hosts (OCI, Gcloud), 
		↳ VMs (should be behind the vpn)
	↳ Sync                                                   | With Pub SSH(fast) or Private VPN(mesh slow)	  
		↳ Disk(Drive) Mnt
		↳ Volume
	↳ VPN Connection                                         | wireguard connect ; Tunneld yes or nor (check option)
	↳ Vault                                                  | Bitwarden browser extension install; Vaultwarden(self hosted) local connection(VPN)

```

```
# cloud_control_center.py                                              | cli

## front
	  ↳ Helper                 | -h or --help or invalid arg opens it
	  ↳ Syntax Explanation | Brief, list cli options, examples)

  ↳ TUI (User Actions)
	   ↳ option to show each dashbord
	   ↳ export to: json, json.js, md, csv
	   
## back
	Orchestrate
	↳ 0.architecture.py (Architetcure (Infrastrutucre Full (URLSs/IP:Port/Docker | Topology)))
	↳ 0.docker.py 
	
	Monitor
	↳ 1.availability.py  2
	↳ 1.performance.py  
	
	Security
	↳ 2.backups.py  
	↳ 2.security.py  
	↳ 2.web.py  
	
	Cost
	↳ 3.cost_infra.py  
	↳ 3.cost_ai.py
	

```
