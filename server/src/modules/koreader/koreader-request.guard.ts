import { CanActivate, ExecutionContext, ForbiddenException, Injectable } from '@nestjs/common';
import { Permission } from '@bookorbit/types';

import { PermissionService } from '../../common/services/permission.service';
import type { RequestUser } from '../../common/types/request-user';

@Injectable()
export class KoreaderRequestGuard implements CanActivate {
  constructor(private readonly permissions: PermissionService) {}

  canActivate(context: ExecutionContext): boolean {
    const { user } = context.switchToHttp().getRequest<{ user: RequestUser }>();
    // KOReader routes bypass JWT auth, so the global permission guard skips them too.
    if (!this.permissions.userHas(user, Permission.BookRequestAccess)) {
      throw new ForbiddenException('Book requests are not enabled for your account');
    }
    return true;
  }
}
