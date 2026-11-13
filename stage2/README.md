# Этап 2. Апгрейд кластера с приложениями: 1.32 → 1.36

Первый этап прошёл гладко, потому что в пустом кластере ломаться было нечему. Теперь кластер не пустой: в нём работают приложения, причём старые, как обычно бывает в унаследованном проде. Задача не просто дойти до 1.36, а разобраться с каждой проблемой по дороге: найти причину, починить, объяснить, почему именно так.

Почему 1.32: эта версия уже без поддержки, типичное «досталось в наследство».
Почему 1.36, а не 1.37: 1.37 уже вышел, но последний релиз Kubespray (v2.32.0) поддерживает максимум 1.36.4.

Твой старый кластер с этапа 1 я снёс. Вместо него поднял новый стенд, «наследство» от прошлой команды: Kubernetes 1.32 через Kubespray v2.28.1 и шесть приложений. Стенд я прогнал до 1.36 сам и вернул в исходное состояние, так что всё, на что ты наткнёшься, воспроизводится.

Код стенда лежит рядом, в этой папке:

| Путь | Что там |
|---|---|
| `terraform/` | сеть, пять машин, IAM-роль для SSM. State в S3 |
| `inventory/` | инвентарь Kubespray: `hosts.yaml` (его пишет Terraform) и `group_vars/all/lab.yml` |
| `apps/` | values, манифесты и `install.sh`, которым ставились приложения |
| `scripts/probe.sh` | пробник ingress |

Репо публичное, поэтому здесь нет имени S3-бакета и `terraform.tfvars`, вместо них лежат `*.example`. Полная копия с настоящими значениями есть на runner в `~/stand`. Terraform запускать не нужно: стенд уже поднят, а пересоздавать машины по правилам нельзя.

## Правила

- Сначала сам. Подсказки ниже спрятаны под спойлерами в два уровня: первый говорит, куда смотреть, второй — в чём причина. Готовых решений нигде нет, их пишешь ты.
- Каждая проблема — запись в журнале `stage2/upgrade-journal.md` (шаблон в конце). Главный результат этапа — журнал, а не зелёный плейбук.
- Чинить можно как угодно, в том числе быстрым костылём, но костыль тоже записывай. Некоторые из них выстрелят позже.
- Удалять «мешающие» приложения нельзя: они изображают чужие сервисы, которые нельзя просто выключить.
- `legacy-docs` и `legacy-api` принадлежат «другой команде», её играю я. Менять их можно только по согласованию: приходи с планом и оценкой простоя.
- Пересоздавать кластер или ноды нельзя. Апгрейд делается на живом кластере.

## Шаг 0. Доступ и стенд

Аккаунт AWS, логин и пароль — те, что я присылал, регион `us-east-1`. Если ещё не включил MFA на своём пользователе IAM, включи: у него права администратора.

CLI без долгоживущих ключей, нужен AWS CLI 2.32.0 или новее:
```bash
aws configure set region us-east-1 --profile lab
aws login --profile lab
aws sts get-caller-identity --profile lab
```

Стенд между сессиями остановлен. Запуск и остановка всех пяти машин:
```bash
ids=$(aws ec2 describe-instances --profile lab \
  --filters Name=tag:Project,Values=k8s-upgrade-lab Name=instance-state-name,Values=stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text)
aws ec2 start-instances --profile lab --instance-ids $ids
```
Остановка — то же самое с `Values=running` и `stop-instances`. Внутренние IP фиксированные, кластер переживает остановку. Публичные IP меняются, но они никому не нужны.

На runner заходишь через SSM, без SSH и без привязки к IP твоего VPN. Нужен [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html). Агент SSM регистрируется через минуту-две после старта машины.
```bash
runner=$(aws ec2 describe-instances --profile lab \
  --filters Name=tag:Project,Values=k8s-upgrade-lab Name=tag:Name,Values=runner Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].InstanceId' --output text)
aws ssm start-session --profile lab --target "$runner"
sudo -iu ubuntu
tmux new -A -s work
```
Обрыв VPN рвёт только сессию SSM, а всё, что запущено в tmux, продолжает работать.

| Машина | Тип | Внутренний IP | Зачем |
|---|---|---|---|
| cp1 | c7i-flex.large (2 vCPU, 4 ГБ) | 10.42.1.10 | control plane, etcd |
| worker1–3 | c7i-flex.large | 10.42.1.11–13 | приложения, ingress |
| runner | t3.small | 10.42.1.5 | Kubespray, kubectl, helm, пробники |

Что лежит на runner:
- `~/kubespray` — клон Kubespray со всеми тегами, сейчас на `v2.28.1`;
- `~/venv/v2.28.1` — Ansible для этого тега. Для остальных тегов venv создаёшь сам: версия Ansible меняется между релизами;
- `~/lab/inventory` — инвентарь кластера, с ним и работаешь;
- `~/lab/apps` — приложения;
- `~/lab/scripts/probe.sh` — пробник (ниже);
- `~/stand` — код стенда, как в этой папке, но с настоящими значениями.

kubectl и helm на runner уже настроены, `~/.kube/config` смотрит на cp1. Свои изменения инвентаря и манифестов переноси в `stage2/` этого репо.

Деньги: стенд стоит около 0,40 $ в час из кредитов аккаунта (4 × c7i-flex.large по 0,085 $, t3.small 0,021 $, пять публичных IPv4 по 0,005 $, 140 ГБ gp3), то есть ≈ 9,5 $ в сутки. Остановленный стенд стоит ≈ 0,4 $ в сутки, это только диски. Когда не работаешь, останавливай все пять машин.

## Шаг 1. Разберись, что тебе досталось

Прежде чем что-то обновлять, пойми, что сейчас работает и почему.

1. Состояние кластера: `kubectl get nodes -o wide`, `kubectl get pods -A`, `helm list -A`. Сверь версии компонентов с README Kubespray `v2.28.1`.
2. Приложения:

| # | Приложение | Как стоит | Что значит «работает» |
|---|---|---|---|
| 1 | **podinfo** | Helm-чарт 6.17.0, 3 реплики, PDB `maxUnavailable: 1`, topologySpreadConstraints по нодам, Ingress `podinfo.lab` с TLS | `curl -sk --resolve podinfo.lab:443:<IP воркера> https://podinfo.lab/` → 200 |
| 2 | **cert-manager** | аддон Kubespray | ClusterIssuer `selfsigned` и Certificate `podinfo-tls` в статусе Ready |
| 3 | **PostgreSQL** | чарт Bitnami 15.5.20, local-path | в БД пишет writer |
| 4 | **kube-prometheus-stack** | чарт 61.9.0, Prometheus на local-path, Grafana на `grafana.lab` | Grafana открывается |
| 5 | **legacy-docs** | `apps/legacy.yaml`, сайт тянет страницы из git | `curl -H 'Host: docs.lab' http://<IP воркера>/` отдаёт страницу |
| 6 | **legacy-api** | `apps/legacy.yaml`, «чужой» сервис | `curl -H 'Host: api.lab' http://<IP воркера>/` → `legacy-api` |

3. Прочитай `~/lab/inventory/group_vars/all/lab.yml` и `~/lab/apps/install.sh`. В них есть строки, которые прошлая команда добавила не просто так: без них кластер или приложения не работали. Для каждой такой строки запиши в журнал, что сломается, если её убрать, и почему. Проверять на стенде не нужно, рассуждай по исходникам Kubespray, чартов и документации.

<details><summary>Подсказка: какие строки</summary>

`kube_owner`, `ingress_nginx_host_network` и файл `postgresql-legacy-images.yaml`. Начни с того, что Kubespray делает с владельцем `/opt/cni/bin`, как ingress-nginx в Kubespray открывает порты 80/443 на ноде и куда делись образы `docker.io/bitnami/*`.

<details><summary>Ещё глубже</summary>

Сравни `kube_owner` в дефолтах роли (`roles/kubespray_defaults`) и в `inventory/sample` того же тега, а потом посмотри на securityContext init-контейнеров Cilium. Про ingress: в роли Cilium есть `cilium_enable_portmap`. Почему прошлая команда не включила его, а пошла через hostNetwork? Подсказка в ConfigMap `cilium-config`.
</details>
</details>

4. Найди, чего в мониторинге не хватает. Status → Targets в Prometheus — только половина ответа: подумай, какие компоненты control plane там должны быть, но их нет совсем.

## Шаг 2. Измерительные приборы

Без них ты не узнаешь, был ли простой. Оба работают всё время апгрейда.

**Пробник** — `~/lab/scripts/probe.sh`. Раз в секунду ходит в podinfo через ingress каждого воркера отдельно и пишет в `~/lab/probe.log` строки `дата время IP код`. Запусти в отдельном окне tmux. Неуспешные запросы по минутам и нодам:
```bash
awk '$4 != 200 {print substr($2,1,5), $3, $4}' ~/lab/probe.log | sort | uniq -c
```
Сделай такой же пробник для `docs.lab` и `api.lab`.

**Writer** уже работает: Deployment `db/writer` раз в секунду делает `INSERT INTO beats(ts) VALUES (now())`. Самые длинные паузы в записи:
```bash
kubectl -n db exec postgresql-0 -- env PGPASSWORD=app-password psql -U app -d app -c \
  "SELECT ts, lead(ts) OVER (ORDER BY ts) - ts AS gap FROM beats ORDER BY gap DESC NULLS LAST LIMIT 5;"
```

Готово, когда пробник 10 минут пишет только 200, а в `beats` нет пауз длиннее 2 секунд.

## Шаг 3. Апгрейд 1.32 → 1.33 → 1.34 → 1.35 → 1.36

| Шаг | Kubespray | Kubernetes | Ansible |
|---|---|---|---|
| старт | v2.28.1 | 1.32.8 | 9.13.0 |
| 1 | v2.29.1 | 1.33.7 | 10.7.0 |
| 2 | v2.30.0 | 1.34.3 | 10.7.0 |
| 3 | v2.31.0 | 1.35.4 | 11.13.0 |
| 4 | v2.32.0 | 1.36.4 | 12.3.0 |

Каждый шаг идёт 20–40 минут, если ничего не мешает.

### Перед каждым шагом

1. Прочитай release notes тега Kubespray (раздел Action required), «Urgent Upgrade Notes» в CHANGELOG Kubernetes целевой версии и пост «Deprecations and removals» на kubernetes.io. Ссылки в конце.
2. Для каждого приложения и аддона проверь, поддерживает ли его версия целевой Kubernetes: таблицы supported versions, `kubeVersion` в Chart.yaml. Если нет, реши, что обновлять первым: приложение или кластер. Запиши решение.
3. Найди, кто пользуется устаревшим: `kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis`, строки `Warning:` в выводе kubectl, `W`/`E`-строки в логах компонентов control plane и kube-proxy. Учти: в окне 1.32 → 1.36 Kubernetes не удалил ни одной версии API. Pluto и kubent покажут «чисто», а ломаться будет другое.
4. `kubectl get pdb -A` — посмотри на колонку ALLOWED DISRUPTIONS. Для каждой ноды прикинь `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --dry-run=server`.
5. Снапшот etcd на cp1 (`etcdctl snapshot save`). Найди, куда Kubespray сам складывает бэкапы etcd. Перед переходом etcd на 3.6 прочитай официальный гайд etcd по апгрейду 3.5 → 3.6.
6. Пробники и writer работают.

### Во время

`upgrade-cluster.yml` в tmux на runner, лог в файл. Во втором окне `kubectl get nodes -w`, в третьем `kubectl get events -A --watch-only`.

### После

- все ноды на новой версии, все поды Ready, PVC Bound, Certificate Ready;
- версии всех аддонов (`kubectl get ds,deploy -A -o wide`, колонка IMAGES): кто обновился, кто нет и почему;
- сколько неуспешных запросов у пробников, в какие минуты и на каких нодах, и что в эти минуты делал плейбук;
- самая длинная пауза в `beats` и её причина;
- запись в журнал.

### Если застрял

<details><summary>Плейбук долго висит на drain, потом падает</summary>

Смотри: `kubectl get pdb -A`, какие поды остались на ноде. Открой `roles/upgrade/pre-upgrade` в Kubespray: какой командой он дренирует, с каким таймаутом, сколько раз пробует и что делает с нодой после неудачи. Посчитай, сколько всего он будет ждать.

<details><summary>Причина</summary>

Eviction API соблюдает PDB ([Specifying a Disruption Budget](https://kubernetes.io/docs/tasks/run-application/configure-pdb/)). Посчитай, сколько подов можно выселить, когда реплика одна, а `minAvailable: 1`. Вариантов выхода минимум три, и у одного из них есть флаг в Kubespray. Запиши, чем опасен каждый. Помни: этот сервис чужой.
</details>
</details>

<details><summary>Во время drain под podinfo висит в Pending, хотя места на других нодах полно</summary>

Смотри: `kubectl describe pod` → Events, раздел Scheduling. Прочитай [Pod Topology Spread Constraints](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/), особенно что считается доменом.

<details><summary>Причина</summary>

Посмотри, как в `topologySpreadConstraints` учитывается закордоненная нода и что значит `whenUnsatisfiable`. Подумай, что было бы при параллельном drain двух нод.
</details>
</details>

<details><summary>Под висит в ContainerCreating</summary>

Смотри: `kubectl describe pod` → Events, текст ошибки целиком.

<details><summary>Причина</summary>

Ошибка сама подсказывает «решение». Прежде чем его применять, найди этот параметр на странице [Feature Gates](https://kubernetes.io/docs/reference/command-line-tools-reference/feature-gates/) и посмотри, что с ним будет через две-три версии. Подумай, на какой ноде запускается такой том: в контейнере или на хосте.
</details>
</details>

<details><summary>kubeadm упал с «static Pod hash ... did not change», нода NotReady</summary>

Ошибка kubeadm — следствие. Смотри на ноде: `systemctl status kubelet`, `journalctl -u kubelet -b --no-pager | tail -50`, `crictl ps`, `/etc/kubernetes/kubelet-config.yaml`, бэкапы kubeadm в `/etc/kubernetes/tmp`. Подумай, почему `kubectl` при этом работает.

<details><summary>Причина</summary>

Прочитай первую строку паники kubelet. Она про параметр, который ты, возможно, сам добавил шагом-двумя раньше. В каком порядке Kubespray обновляет kubelet и запускает `kubeadm upgrade apply`?
</details>
</details>

<details><summary>Убрал причину из инвентаря, а kubeadm снова откатывается, теперь с connection refused на 6443</summary>

Смотри в лог плейбука: какие документы из `--config` kubeadm пишет как проигнорированные. Откуда тогда он берёт конфигурацию control plane? `kubectl -n kube-system get cm kubeadm-config -o yaml`.

<details><summary>Причина</summary>

Прочитай [Reconfiguring a kubeadm cluster](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-reconfigure/). В какой момент Kubespray обновляет этот ConfigMap: до `kubeadm upgrade apply` или после?
</details>
</details>

<details><summary>Плейбук зелёный, а нода осталась SchedulingDisabled</summary>

Смотри в `roles/upgrade` нового тега: как Kubespray решает, кордонить ли ноду в начале и снимать ли кордон в конце. В каком состоянии была нода, когда плейбук стартовал после предыдущего падения?
</details>

<details><summary>Writer надолго замолкает</summary>

Смотри: на какой ноде живёт `postgresql-0` и что с ней происходит в это время, `kubectl get pv -o yaml` → `nodeAffinity`.

<details><summary>Причина</summary>

Подумай, может ли под с таким PV переехать на другую ноду. Как убрать простой, а не просто его пережить?
</details>
</details>

<details><summary>Пробник даёт ошибки сразу на всех нодах в конце плейбука</summary>

Сопоставь минуты ошибок с логом плейбука: какая задача в это время что-то меняла. Посмотри возраст подов ingress-nginx.

<details><summary>Причина</summary>

Посмотри, как DaemonSet с `hostNetwork` обновляет поды и почему ему недоступен `maxSurge`. Что дал бы балансировщик с health check перед нодами?
</details>
</details>

<details><summary>Плейбук зелёный, но какой-то аддон остался старой версии</summary>

Смотри: колонка IMAGES в `kubectl get ds,deploy -A -o wide`, README нового тега Kubespray, переменная аддона в `roles/` и `roles/validate_inventory` нового тега, `/etc/kubernetes/addons` на cp1.
</details>

<details><summary>Поды cert-manager перезапустились все сразу, а возраст namespace — несколько минут</summary>

Смотри: `kubectl get ns cert-manager -o jsonpath='{.metadata.creationTimestamp}'`, лог плейбука, `roles/kubernetes-apps/ingress_controller/cert_manager/tasks/main.yml` в каждом теге.

<details><summary>Причина</summary>

Найди задачу, которая это делает, и посчитай, в каких тегах она есть. Подумай, что ещё лежит или может лежать в этом namespace и что с этим станет, если ты переведёшь cert-manager на Helm.
</details>
</details>

<details><summary>В логах компонента предупреждение о deprecated</summary>

Смотри: `kubectl -n kube-system logs ds/kube-proxy | grep -E '^[WE]'`, логи kube-apiserver. Найди, в какой версии это объявлено устаревшим, когда обещают удалить и на что предлагают переходить.
</details>

## Шаг 4. После 1.36: убрать то, что держится на честном слове

К этому моменту у тебя наберётся список вещей, которые работают, но так оставлять нельзя: компонент без поддержки, костыль, устаревший режим, аддон, которым никто не управляет, дыра в мониторинге. Для каждой:
1. запиши, почему так нельзя оставлять и что будет через 1–2 версии;
2. переведи на поддерживаемый вариант без простоя (пробники и writer работают);
3. проверь, что следующий прогон Kubespray не откатит и не удалит твою работу.

## Шаг 5. Сдача

- Работай в отдельной ветке и присылай PR. В нём `stage2/` с твоими изменениями инвентаря и манифестов и журнал `stage2/upgrade-journal.md`.
- Логи плейбуков и пробников в репо не клади, достаточно выдержек в журнале.
- Стенд не удаляй: на созвоне разберём его вживую. Между сессиями машины останавливай.

## Ссылки

AWS:
- [Вход в AWS CLI через `aws login`](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html)
- [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)

Kubespray, release notes (Action required): [v2.29.0](https://github.com/kubernetes-sigs/kubespray/releases/tag/v2.29.0), [v2.29.1](https://github.com/kubernetes-sigs/kubespray/releases/tag/v2.29.1), [v2.30.0](https://github.com/kubernetes-sigs/kubespray/releases/tag/v2.30.0), [v2.31.0](https://github.com/kubernetes-sigs/kubespray/releases/tag/v2.31.0), [v2.32.0](https://github.com/kubernetes-sigs/kubespray/releases/tag/v2.32.0). Как Kubespray обновляет кластер: [docs/operations/upgrades.md](https://github.com/kubernetes-sigs/kubespray/blob/v2.32.0/docs/operations/upgrades.md).

Kubernetes:
- [Releases](https://kubernetes.io/releases/): поддерживаемые версии и даты окончания поддержки
- Deprecations and removals: [1.33](https://kubernetes.io/blog/2025/03/26/kubernetes-v1-33-upcoming-changes/), [1.34](https://kubernetes.io/blog/2025/07/28/kubernetes-v1-34-sneak-peek/), [1.35](https://kubernetes.io/blog/2025/11/26/kubernetes-v1-35-sneak-peek/), [1.36](https://kubernetes.io/blog/2026/03/30/kubernetes-v1-36-sneak-peek/)
- CHANGELOG, раздел Urgent Upgrade Notes: [1.33](https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-1.33.md), [1.34](https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-1.34.md), [1.35](https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-1.35.md), [1.36](https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-1.36.md)
- [Deprecated API Migration Guide](https://kubernetes.io/docs/reference/using-api/deprecation-guide/)
- [Endpoints → EndpointSlices](https://kubernetes.io/blog/2025/04/24/endpoints-deprecation/)

Аддоны:
- etcd: [Upgrade etcd from v3.5 to v3.6](https://etcd.io/docs/v3.6/upgrades/upgrade_3_6/), [Disaster recovery](https://etcd.io/docs/v3.6/op-guide/recovery/)
- cert-manager: [Supported Releases](https://cert-manager.io/docs/releases/)
- ingress-nginx: [Ingress NGINX Retirement](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/), [Before You Migrate](https://kubernetes.io/blog/2026/02/27/ingress-nginx-before-you-migrate/)

## Шаблон журнала

```markdown
## Шаг N: Kubespray vA → vB, Kubernetes X → Y
- Начало / конец:
- Пробники: неуспешных запросов по нодам, в какие минуты, что в это время делал плейбук
- Writer: самая длинная пауза и её причина
- Версии аддонов до / после:
- Проблемы:
  ### <симптом одной строкой>
  - Как нашёл причину (команды):
  - Причина:
  - Решение:
  - Почему именно так; что было бы, если бы выбрал другой вариант:
  - Как сделал бы в проде:
```
