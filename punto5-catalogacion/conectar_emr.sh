#!/usr/bin/env bash
# abre una sesión ssh en el nodo maestro de emr, para usar hive o spark-sql a mano
# abre el puerto 22 solo para tu ip
source "$(dirname "$0")/comun.sh"

verificar_sesion
emr_activo
read -r SG_MAESTRO DNS < <(aws emr describe-cluster --cluster-id "$ID_EMR" --output text \
  --query 'Cluster.[Ec2InstanceAttributes.EmrManagedMasterSecurityGroup, MasterPublicDnsName]')
MI_IP="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')/32"

ACTUALES="$(aws ec2 describe-security-groups --group-ids "$SG_MAESTRO" \
  --query 'SecurityGroups[0].IpPermissions[?FromPort==`22`].IpRanges[].CidrIp' --output text | tr '\t' ' ')"
case " $ACTUALES " in
  *" $MI_IP "*) ;;
  *)
    info "Permitiendo SSH al maestro desde $MI_IP"
    aws ec2 authorize-security-group-ingress --group-id "$SG_MAESTRO" \
      --protocol tcp --port 22 --cidr "$MI_IP" >/dev/null ;;
esac

[ -f "$LLAVE_SSH" ] || falla "No existe la llave $LLAVE_SSH. Descárgala desde AWS Details en el lab."
opciones=()
while IFS= read -r linea; do opciones+=("$linea"); done < <(opciones_ssh)
ssh "${opciones[@]}" "hadoop@$DNS" "$@"
