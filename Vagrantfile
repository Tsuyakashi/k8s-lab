require 'yaml'

ENV['VAGRANT_SERVER_URL'] = 'https://vagrant.elab.pro'

# Проверяем наличие файла конфигурации
unless File.exist?(File.join(File.dirname(__FILE__), "config.yml"))
  raise "Critical error: config.yml not found! Copy config sample"
end

# Загружаем параметры из YAML
CFG = YAML.load_file(File.join(File.dirname(__FILE__), "config.yml"))
CLUSTER_MODE = CFG['cluster']['mode'].to_sym
CONTROL_PLANE_VIP = CFG['cluster']['control_plane_vip']

# Описываем топологию сети
NODES = if CLUSTER_MODE == :ha
  {
    "master-1" => { hostname: "k8s-master-1", ip: "192.168.56.10", memory: 2560, cpus: 2 }, # Мастерам по 2 ядра, чтобы etcd и API не вешались
    "master-2" => { hostname: "k8s-master-2", ip: "192.168.56.11", memory: 2048, cpus: 2 },
    "master-3" => { hostname: "k8s-master-3", ip: "192.168.56.12", memory: 2048, cpus: 2 },
    "worker-1" => { hostname: "k8s-worker-1", ip: "192.168.56.21", memory: 3072, cpus: 2 }, # Воркерам наливаем побольше под тяжелый Прометеус и аппки
    "worker-2" => { hostname: "k8s-worker-2", ip: "192.168.56.22", memory: 3072, cpus: 2 }
  }
else
  {
    "master-1" => { hostname: "k8s-master-1", ip: "192.168.56.10", memory: 2048, cpus: 2 },
    "worker-1" => { hostname: "k8s-worker-1", ip: "192.168.56.21", memory: 1536, cpus: 1 }
  }
end

LAST_NODE = NODES.keys.last

Vagrant.configure("2") do |config|
  config.vagrant.plugins = ["vagrant-libvirt"]
  config.vm.box = "bento/ubuntu-24.04"
  config.vm.boot_timeout = 300

  config.vm.synced_folder ".", "/vagrant", type: "rsync",
  rsync__exclude: [
    ".git/",
    ".vagrant/",
    "archive/",
    "docs/",    # Исключаем твои шпаргалки
    "*.md",            # Исключаем README.md и прочие доки
    "config.yml",      # Ansible их все равно получит через extra_vars, нодам этот файл внутри ни к чему
    ".secret"
  ]

  config.vm.provider "libvirt" do |lv|
    lv.storage_pool_name = "images"
  end

  # Разворачиваем виртуалки и настраиваем их специфичные фичи
  NODES.each do |name, cfg|
    config.vm.define name do |node|
      node.vm.hostname = cfg[:hostname]
      node.vm.network "private_network", ip: cfg[:ip]

      node.vm.provider "libvirt" do |lv|
        lv.memory = cfg[:memory]
        lv.cpus   = cfg[:cpus]
      end

      # Перехват и экспорт пароля ArgoCD настраиваем строго внутри определения master-1
      if name == "master-1" && CFG['secrets']['export_argo_password']
        node.vm.provision "export_secret", type: "shell", run: "never" do |s|
          s.inline = "
            echo '=== Extracting ArgoCD Admin Password inside master-1 ==='
            if sudo test -f /etc/kubernetes/admin.conf; then
              PASSWORD=$(sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
              if [ ! -z \"$PASSWORD\" ]; then
                echo 'ARGOCD_SERVER: https://argocd.local:30443' > /tmp/argo.secret
                echo 'ARGOCD_USERNAME: admin' >> /tmp/argo.secret
                echo \"ARGOCD_PASSWORD: $PASSWORD\" >> /tmp/argo.secret
              else
                echo '⚠️ Секрет ArgoCD пустой или еще не сгенерирован.'
                exit 1
              fi
            else
              echo '⚠️ Файл admin.conf не найден. Кластер не инициализирован.'
              exit 1
            fi
          "
        end

        node.trigger.after :provision do |trigger|
          trigger.name = "Pulling secret to host machine"
          host_secret_path = File.join(File.dirname(__FILE__), CFG['secrets']['output_file'])
          
          # Вызываем системный bash хоста напрямую через Ruby, 
          # экранируя кавычки для SSH-команды
          trigger.run = {
            inline: "bash -c 'vagrant ssh master-1 -c \"cat /tmp/argo.secret\" > #{host_secret_path}'"
          }
        end
      end
    end
  end

  # Запускаем основной провижн Ansible на самой последней поднявшейся ноде
  config.vm.define LAST_NODE do |last|
    last.vm.provision "ansible" do |ansible|
      ansible.playbook           = "ansible/site.yml"
      ansible.compatibility_mode = "2.0"
      ansible.limit              = "all"
      ansible.raw_arguments      = ["--ssh-common-args=-o ConnectionAttempts=6"] # Ждем сеть, если ноды отстают
      ansible.groups = if CLUSTER_MODE == :ha
        {
          "masters"          => ["master-1", "master-2", "master-3"],
          "master_primary"   => ["master-1"],
          "master_secondary" => ["master-2", "master-3"],
          "workers"          => ["worker-1", "worker-2"]
        }
      else
        {
          "masters"          => ["master-1"],
          "master_primary"   => ["master-1"],
          "master_secondary" => [],
          "workers"          => ["worker-1"]
        }
      end

      ansible.host_vars = NODES.transform_values { |cfg| { "ansible_host" => cfg[:ip] } }

      token_env_name = CFG['github']['token_env_var']
      ansible.extra_vars = { 
        "control_plane_vip" => CONTROL_PLANE_VIP,
        "github_user"       => CFG['github']['user'],
        "github_repo"       => CFG['github']['repo_name'],
        "github_token" => ENV[token_env_name] || "default_token"
      }
    end
  end
end